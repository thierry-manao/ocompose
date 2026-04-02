const http = require('http');
const fs = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);

const PROJECT_DIR = path.resolve(__dirname, '..');
const INSTANCES_DIR = path.join(PROJECT_DIR, 'instances');
const TEMPLATE_PATH = path.join(PROJECT_DIR, '.env.example');
const PUBLIC_DIR = path.join(__dirname, 'public');
const SCRIPT_PATH = path.join(PROJECT_DIR, 'scripts', 'ocompose.sh');

function parsePort(value) {
    if (value == null || value === '') {
        return null;
    }

    const parsed = Number.parseInt(String(value), 10);
    if (Number.isNaN(parsed) || parsed < 1 || parsed > 65535) {
        return null;
    }

    return parsed;
}

const PORT = parsePort(process.argv[2]) || parsePort(process.env.OCOMPOSE_UI_PORT) || 8787;
const AUTH_USERNAME = normalizeCredential(process.env.OCOMPOSE_UI_USERNAME || 'admin');
const AUTH_PASSWORD = normalizeCredential(process.env.OCOMPOSE_UI_PASSWORD || '');
const SESSION_COOKIE_NAME = 'ocompose_ui_session';
const SESSION_TTL_MS = 1000 * 60 * 60 * 12;
const sessions = new Map();

const MIME_TYPES = {
    '.css': 'text/css; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
};

function sendJson(response, statusCode, payload) {
    response.writeHead(statusCode, { 'Content-Type': MIME_TYPES['.json'] });
    response.end(JSON.stringify(payload));
}

function redirect(response, location) {
    response.writeHead(302, { Location: location });
    response.end();
}

function sendText(response, statusCode, payload) {
    response.writeHead(statusCode, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end(payload);
}

function normalizeValue(value) {
    if (value == null) {
        return '';
    }

    return String(value).trim();
}

function normalizeCredential(value) {
    return String(value || '').trim();
}

function timingSafeEquals(left, right) {
    const leftBuffer = Buffer.from(left);
    const rightBuffer = Buffer.from(right);

    if (leftBuffer.length !== rightBuffer.length) {
        return false;
    }

    return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function parseCookies(request) {
    const cookieHeader = request.headers.cookie || '';
    const cookies = {};

    for (const pair of cookieHeader.split(';')) {
        const separatorIndex = pair.indexOf('=');
        if (separatorIndex === -1) {
            continue;
        }

        const key = pair.slice(0, separatorIndex).trim();
        const value = pair.slice(separatorIndex + 1).trim();
        cookies[key] = decodeURIComponent(value);
    }

    return cookies;
}

function setSessionCookie(response, token) {
    response.setHeader('Set-Cookie', `${SESSION_COOKIE_NAME}=${encodeURIComponent(token)}; HttpOnly; Path=/; SameSite=Lax; Max-Age=${SESSION_TTL_MS / 1000}`);
}

function clearSessionCookie(response) {
    response.setHeader('Set-Cookie', `${SESSION_COOKIE_NAME}=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0`);
}

function createSession(username) {
    const token = crypto.randomBytes(32).toString('hex');
    sessions.set(token, {
        username,
        expiresAt: Date.now() + SESSION_TTL_MS,
    });
    return token;
}

function getSession(request) {
    const cookies = parseCookies(request);
    const token = cookies[SESSION_COOKIE_NAME];
    if (!token) {
        return null;
    }

    const session = sessions.get(token);
    if (!session) {
        return null;
    }

    if (session.expiresAt <= Date.now()) {
        sessions.delete(token);
        return null;
    }

    session.expiresAt = Date.now() + SESSION_TTL_MS;
    return { token, ...session };
}

function isPublicRoute(url) {
    return url.pathname === '/login' || url.pathname === '/login.js' || url.pathname === '/styles.css' || url.pathname === '/api/auth/login';
}

function ensureAuthenticated(request, response, url) {
    const session = getSession(request);
    if (session) {
        return session;
    }

    if (url.pathname.startsWith('/api/')) {
        sendJson(response, 401, { error: 'Authentication required.' });
        return null;
    }

    redirect(response, '/login');
    return null;
}

function parseEnv(content) {
    const values = {};
    const lines = content.split(/\r?\n/);

    for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) {
            continue;
        }

        const separatorIndex = line.indexOf('=');
        if (separatorIndex === -1) {
            continue;
        }

        const key = line.slice(0, separatorIndex).trim();
        let value = line.slice(separatorIndex + 1).trim();

        if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
            value = value.slice(1, -1);
        }

        values[key] = value.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }

    return values;
}

function parseTemplate(content) {
    return content.split(/\r?\n/).map((line) => {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#') || !line.includes('=')) {
            return { type: 'raw', line };
        }

        const separatorIndex = line.indexOf('=');
        return {
            type: 'entry',
            key: line.slice(0, separatorIndex).trim(),
            line,
        };
    });
}

function formatEnvValue(value) {
    const normalized = normalizeValue(value);
    if (normalized === '') {
        return '';
    }

    if (/\s/.test(normalized) || normalized.includes('"')) {
        return `"${normalized.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
    }

    return normalized;
}

async function loadTemplate() {
    const templateContent = await fs.readFile(TEMPLATE_PATH, 'utf8');
    return {
        defaults: parseEnv(templateContent),
        lines: parseTemplate(templateContent),
    };
}

async function readInstanceConfig(instanceName) {
    const envPath = path.join(INSTANCES_DIR, instanceName, '.env');
    const raw = await fs.readFile(envPath, 'utf8');
    return parseEnv(raw);
}

async function readResolvedInstanceConfig(instanceName) {
    const [template, config] = await Promise.all([
        loadTemplate(),
        readInstanceConfig(instanceName),
    ]);

    return {
        ...template.defaults,
        ...config,
        PROJECT_NAME: instanceName,
    };
}

async function writeInstanceConfig(instanceName, configUpdates) {
    const template = await loadTemplate();
    const envPath = path.join(INSTANCES_DIR, instanceName, '.env');
    const currentConfig = await readInstanceConfig(instanceName);
    const mergedConfig = {
        ...template.defaults,
        ...currentConfig,
        ...configUpdates,
        PROJECT_NAME: instanceName,
    };

    const rendered = template.lines.map((entry) => {
        if (entry.type !== 'entry') {
            return entry.line;
        }

        return `${entry.key}=${formatEnvValue(mergedConfig[entry.key])}`;
    });

    for (const [key, value] of Object.entries(mergedConfig)) {
        const existsInTemplate = template.lines.some((entry) => entry.type === 'entry' && entry.key === key);
        if (!existsInTemplate) {
            rendered.push(`${key}=${formatEnvValue(value)}`);
        }
    }

    await fs.writeFile(envPath, `${rendered.join('\n')}\n`, 'utf8');
}

async function listInstanceNames() {
    try {
        const entries = await fs.readdir(INSTANCES_DIR, { withFileTypes: true });
        return entries
            .filter((entry) => entry.isDirectory())
            .map((entry) => entry.name)
            .sort((left, right) => left.localeCompare(right));
    } catch (error) {
        if (error.code === 'ENOENT') {
            return [];
        }

        throw error;
    }
}

async function getRunningContainers() {
    try {
        const { stdout } = await execFileAsync('docker', ['ps', '--format', '{{.Names}}'], {
            cwd: PROJECT_DIR,
            maxBuffer: 1024 * 1024,
        });
        return new Set(stdout.split(/\r?\n/).filter(Boolean));
    } catch (error) {
        return new Set();
    }
}

function toBoolean(value) {
    return normalizeValue(value).toLowerCase() === 'true';
}

function sanitizeConfig(inputConfig) {
    const allowedKeys = new Set([
        'WORKSPACE_USER',
        'WORKSPACE_UID',
        'WORKSPACE_GID',
        'WORKSPACE_SHELL',
        'PHP_ENABLED',
        'PHP_VERSION',
        'PHP_EXTENSIONS',
        'APP_PORT',
        'MYSQL_ENABLED',
        'MYSQL_VERSION',
        'MYSQL_ROOT_PASSWORD',
        'MYSQL_DATABASE',
        'MYSQL_USER',
        'MYSQL_PASSWORD',
        'MYSQL_PORT',
        'PHPMYADMIN_ENABLED',
        'PHPMYADMIN_PORT',
        'WORKSPACE_SSH_PORT',
    ]);

    const sanitized = {};
    for (const [key, value] of Object.entries(inputConfig || {})) {
        if (allowedKeys.has(key)) {
            sanitized[key] = normalizeValue(value);
        }
    }

    return sanitized;
}

function buildInstanceSummary(instanceName, config, runningContainers) {
    const running = runningContainers.has(`${instanceName}_workspace`);
    return {
        name: instanceName,
        status: running ? 'running' : 'stopped',
        config,
        urls: {
            app: toBoolean(config.PHP_ENABLED) ? `http://localhost:${config.APP_PORT}` : null,
            phpmyadmin: toBoolean(config.PHPMYADMIN_ENABLED) ? `http://localhost:${config.PHPMYADMIN_PORT}` : null,
            ssh: config.WORKSPACE_SSH_PORT ? `localhost:${config.WORKSPACE_SSH_PORT}` : null,
        },
    };
}

function validateInstanceName(instanceName) {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(instanceName || '')) {
        throw new Error('Instance names may only contain letters, numbers, hyphens, and underscores.');
    }
}

async function runOcompose(args) {
    const command = process.platform === 'win32' ? 'bash' : SCRIPT_PATH;
    const commandArgs = process.platform === 'win32' ? [SCRIPT_PATH, ...args] : args;

    return execFileAsync(command, commandArgs, {
        cwd: PROJECT_DIR,
        maxBuffer: 1024 * 1024,
        env: process.env,
    });
}

async function getInstance(instanceName) {
    const [config, runningContainers] = await Promise.all([
        readResolvedInstanceConfig(instanceName),
        getRunningContainers(),
    ]);

    return buildInstanceSummary(instanceName, config, runningContainers);
}

async function listInstances() {
    const [instanceNames, runningContainers] = await Promise.all([
        listInstanceNames(),
        getRunningContainers(),
    ]);

    const instances = [];
    for (const instanceName of instanceNames) {
        try {
            const config = await readResolvedInstanceConfig(instanceName);
            instances.push(buildInstanceSummary(instanceName, config, runningContainers));
        } catch (error) {
            instances.push({
                name: instanceName,
                status: 'invalid',
                config: {},
                urls: { app: null, phpmyadmin: null, ssh: null },
                error: error.message,
            });
        }
    }

    return instances;
}

async function readRequestBody(request) {
    const chunks = [];
    for await (const chunk of request) {
        chunks.push(chunk);
    }

    if (chunks.length === 0) {
        return {};
    }

    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function serveStaticFile(response, filePath) {
    const resolvedPath = path.resolve(PUBLIC_DIR, filePath);
    if (!resolvedPath.startsWith(PUBLIC_DIR)) {
        sendText(response, 403, 'Forbidden');
        return;
    }

    try {
        const content = await fs.readFile(resolvedPath);
        const extension = path.extname(resolvedPath).toLowerCase();
        response.writeHead(200, { 'Content-Type': MIME_TYPES[extension] || 'application/octet-stream' });
        response.end(content);
    } catch (error) {
        if (error.code === 'ENOENT') {
            sendText(response, 404, 'Not found');
            return;
        }

        throw error;
    }
}

async function handleApi(request, response, url) {
    const pathParts = url.pathname.split('/').filter(Boolean);

    if (request.method === 'POST' && url.pathname === '/api/auth/login') {
        const body = await readRequestBody(request);
        const username = normalizeCredential(body.username);
        const password = normalizeCredential(body.password);

        if (!AUTH_PASSWORD) {
            sendJson(response, 500, { error: 'UI authentication is not configured.' });
            return;
        }

        if (!timingSafeEquals(username, AUTH_USERNAME) || !timingSafeEquals(password, AUTH_PASSWORD)) {
            sendJson(response, 401, { error: 'Invalid username or password.' });
            return;
        }

        const token = createSession(username);
        setSessionCookie(response, token);
        sendJson(response, 200, { ok: true, username });
        return;
    }

    if (request.method === 'POST' && url.pathname === '/api/auth/logout') {
        const session = getSession(request);
        if (session) {
            sessions.delete(session.token);
        }
        clearSessionCookie(response);
        sendJson(response, 200, { ok: true });
        return;
    }

    if (request.method === 'GET' && url.pathname === '/api/auth/session') {
        const session = getSession(request);
        if (!session) {
            sendJson(response, 401, { error: 'Authentication required.' });
            return;
        }

        sendJson(response, 200, { ok: true, username: session.username });
        return;
    }

    if (request.method === 'GET' && url.pathname === '/api/instances') {
        sendJson(response, 200, { instances: await listInstances() });
        return;
    }

    if (request.method === 'POST' && url.pathname === '/api/instances') {
        const body = await readRequestBody(request);
        const instanceName = normalizeValue(body.name);
        validateInstanceName(instanceName);
        await runOcompose([instanceName, 'init', '--yes']);
        sendJson(response, 201, { instance: await getInstance(instanceName) });
        return;
    }

    if (pathParts.length === 3 && pathParts[0] === 'api' && pathParts[1] === 'instances') {
        const instanceName = pathParts[2];

        if (request.method === 'GET') {
            sendJson(response, 200, { instance: await getInstance(instanceName) });
            return;
        }

        if (request.method === 'PUT') {
            const body = await readRequestBody(request);
            validateInstanceName(instanceName);
            await writeInstanceConfig(instanceName, sanitizeConfig(body.config));
            sendJson(response, 200, { instance: await getInstance(instanceName) });
            return;
        }
    }

    if (pathParts.length === 5 && pathParts[0] === 'api' && pathParts[1] === 'instances' && pathParts[3] === 'actions') {
        const instanceName = pathParts[2];
        const action = pathParts[4];
        validateInstanceName(instanceName);

        const actionArgs = {
            up: [instanceName, 'up'],
            down: [instanceName, 'down'],
            restart: [instanceName, 'restart'],
            destroy: [instanceName, 'destroy', '--yes'],
        };

        if (!actionArgs[action]) {
            sendJson(response, 400, { error: 'Unsupported action.' });
            return;
        }

        const result = await runOcompose(actionArgs[action]);
        if (action === 'destroy') {
            sendJson(response, 200, { output: result.stdout || result.stderr || 'Destroyed.' });
            return;
        }

        sendJson(response, 200, {
            instance: await getInstance(instanceName),
            output: result.stdout || result.stderr || '',
        });
        return;
    }

    sendJson(response, 404, { error: 'Not found.' });
}

const server = http.createServer(async (request, response) => {
    try {
        const url = new URL(request.url, `http://${request.headers.host || `localhost:${PORT}`}`);

        if (!isPublicRoute(url)) {
            const session = ensureAuthenticated(request, response, url);
            if (!session) {
                return;
            }
        }

        if (url.pathname === '/login' && getSession(request)) {
            redirect(response, '/');
            return;
        }

        if (url.pathname.startsWith('/api/')) {
            await handleApi(request, response, url);
            return;
        }

        const relativePath = url.pathname === '/'
            ? 'index.html'
            : url.pathname === '/login'
                ? 'login.html'
                : url.pathname.slice(1);
        await serveStaticFile(response, relativePath);
    } catch (error) {
        const statusCode = error.code === 'ENOENT' ? 404 : 500;
        sendJson(response, statusCode, { error: error.message || 'Unexpected server error.' });
    }
});

server.on('error', (error) => {
    if (error.code === 'EADDRINUSE') {
        console.error(`ocompose web UI could not start because port ${PORT} is already in use.`);
        process.exit(1);
    }

    throw error;
});

server.listen(PORT, () => {
    if (!AUTH_PASSWORD) {
        console.warn('ocompose web UI authentication is not configured. Set OCOMPOSE_UI_PASSWORD before starting the server.');
    }
    console.log(`ocompose web UI listening on http://localhost:${PORT}`);
});