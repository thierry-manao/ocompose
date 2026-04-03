const http = require('http');
const fs = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);

const PROJECT_DIR = path.resolve(__dirname, '..');
const PUBLIC_DIR = path.join(__dirname, 'public');
const INSTANCES_DIR = path.join(PROJECT_DIR, 'instances');
const DB_DIR = path.join(PROJECT_DIR, 'db');
const TEMPLATE_PATH = path.join(PROJECT_DIR, '.env.example');
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
const AUTH_USERNAME = String(process.env.OCOMPOSE_UI_USERNAME || 'admin').trim();
const AUTH_PASSWORD = String(process.env.OCOMPOSE_UI_PASSWORD || '').trim();
const SESSION_COOKIE = 'ocompose_ui_session';
const SESSION_TTL_MS = 1000 * 60 * 60 * 12;
const sessions = new Map();
const consoleSessions = new Map();
const CONSOLE_SESSION_TTL_MS = 1000 * 60 * 30;
const CONSOLE_BUFFER_LIMIT = 200000;
const CONSOLE_BUFFER_TRIM_TO = 150000;

const MIME_TYPES = {
    '.css': 'text/css; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
};

function send(response, statusCode, body, contentType = 'text/plain; charset=utf-8', headers = {}) {
    response.writeHead(statusCode, {
        'Content-Type': contentType,
        ...headers,
    });
    response.end(body);
}

function sendJson(response, statusCode, payload, headers = {}) {
    send(response, statusCode, JSON.stringify(payload), MIME_TYPES['.json'], headers);
}

function redirect(response, location, headers = {}) {
    response.writeHead(302, {
        Location: location,
        ...headers,
    });
    response.end();
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
    response.setHeader('Set-Cookie', `${SESSION_COOKIE}=${encodeURIComponent(token)}; HttpOnly; Path=/; SameSite=Lax; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`);
}

function clearSessionCookie(response) {
    response.setHeader('Set-Cookie', `${SESSION_COOKIE}=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0`);
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
    const token = parseCookies(request)[SESSION_COOKIE];
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

function timingSafeEquals(left, right) {
    const leftBuffer = Buffer.from(String(left));
    const rightBuffer = Buffer.from(String(right));

    if (leftBuffer.length !== rightBuffer.length) {
        return false;
    }

    return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

async function readJsonBody(request) {
    const chunks = [];

    for await (const chunk of request) {
        chunks.push(chunk);
    }

    if (chunks.length === 0) {
        return {};
    }

    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function normalizeValue(value) {
    if (value == null) {
        return '';
    }

    return String(value).trim();
}

function parseEnv(content) {
    const values = {};

    for (const line of content.split(/\r?\n/)) {
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
    const raw = await fs.readFile(TEMPLATE_PATH, 'utf8');
    return {
        defaults: parseEnv(raw),
        lines: parseTemplate(raw),
    };
}

async function readInstanceConfig(instanceName) {
    const raw = await fs.readFile(path.join(INSTANCES_DIR, instanceName, '.env'), 'utf8');
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

async function writeInstanceConfig(instanceName, updates) {
    const envPath = path.join(INSTANCES_DIR, instanceName, '.env');
    const [template, currentConfig] = await Promise.all([
        loadTemplate(),
        readInstanceConfig(instanceName),
    ]);

    const merged = {
        ...template.defaults,
        ...currentConfig,
        ...updates,
        PROJECT_NAME: instanceName,
    };

    const lines = template.lines.map((entry) => {
        if (entry.type !== 'entry') {
            return entry.line;
        }

        return `${entry.key}=${formatEnvValue(merged[entry.key])}`;
    });

    for (const [key, value] of Object.entries(merged)) {
        const exists = template.lines.some((entry) => entry.type === 'entry' && entry.key === key);
        if (!exists) {
            lines.push(`${key}=${formatEnvValue(value)}`);
        }
    }

    await fs.writeFile(envPath, `${lines.join('\n')}\n`, 'utf8');
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

async function listDbFiles() {
    try {
        const entries = await fs.readdir(DB_DIR, { withFileTypes: true });
        return entries
            .filter((entry) => entry.isFile() && /\.sql(\.gz)?$/i.test(entry.name))
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

function getRequestHostname(request) {
    const forwardedHost = normalizeValue(request.headers['x-forwarded-host']);
    const hostHeader = (forwardedHost || normalizeValue(request.headers.host) || `localhost:${PORT}`).split(',')[0].trim();

    try {
        return new URL(`http://${hostHeader}`).hostname;
    } catch (error) {
        return 'localhost';
    }
}

function buildInstanceSummary(instanceName, config, runningContainers, accessHost = 'localhost') {
    const running = runningContainers.has(`${instanceName}_workspace`);

    return {
        name: instanceName,
        status: running ? 'running' : 'stopped',
        config,
        urls: {
            app: toBoolean(config.PHP_ENABLED) ? `http://${accessHost}:${config.APP_PORT}` : null,
            phpmyadmin: toBoolean(config.PHPMYADMIN_ENABLED) ? `http://${accessHost}:${config.PHPMYADMIN_PORT}` : null,
            ssh: config.WORKSPACE_SSH_PORT ? `${accessHost}:${config.WORKSPACE_SSH_PORT}` : null,
        },
    };
}

function getWorkspaceContainerName(instanceName) {
    return `${instanceName}_workspace`;
}

function getWorkspaceDirectory(config) {
    const workspaceUser = normalizeValue(config.WORKSPACE_USER) || 'developer';
    return `/home/${workspaceUser}/workspace`;
}

function appendConsoleOutput(consoleSession, text) {
    if (!text) {
        return;
    }

    consoleSession.output += text;
    if (consoleSession.output.length > CONSOLE_BUFFER_LIMIT) {
        const trimLength = consoleSession.output.length - CONSOLE_BUFFER_TRIM_TO;
        consoleSession.output = consoleSession.output.slice(trimLength);
        consoleSession.baseCursor += trimLength;
    }
}

function touchConsoleSession(consoleSession) {
    consoleSession.lastActivityAt = Date.now();
}

function removeConsoleSession(consoleSession) {
    consoleSessions.delete(consoleSession.id);
}

function closeConsoleSession(consoleSession) {
    if (!consoleSession) {
        return;
    }

    if (!consoleSession.closed) {
        consoleSession.closed = true;
        consoleSession.busy = false;
        try {
            consoleSession.process.stdin.write('__OCOMPOSE_EXIT__\n');
        } catch (error) {
            // Ignore write failures during shutdown.
        }
        consoleSession.process.kill();
    }

    removeConsoleSession(consoleSession);
}

function cleanupConsoleSessions() {
    const now = Date.now();
    for (const consoleSession of consoleSessions.values()) {
        if (consoleSession.closed || consoleSession.lastActivityAt + CONSOLE_SESSION_TTL_MS <= now) {
            closeConsoleSession(consoleSession);
        }
    }
}

function getConsoleSession(sessionId, ownerToken, instanceName) {
    const consoleSession = consoleSessions.get(sessionId);
    if (!consoleSession || consoleSession.ownerToken !== ownerToken || consoleSession.instanceName !== instanceName || consoleSession.closed) {
        return null;
    }

    touchConsoleSession(consoleSession);
    return consoleSession;
}

function flushConsoleStream(consoleSession, streamName) {
    const bufferKey = `${streamName}Buffer`;
    const markerPrefix = `${consoleSession.marker}:`;
    let buffer = consoleSession[bufferKey];
    let newlineIndex = buffer.indexOf('\n');

    while (newlineIndex !== -1) {
        const rawLine = buffer.slice(0, newlineIndex);
        const line = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine;

        if (line.startsWith(`${markerPrefix}READY:`)) {
            consoleSession.cwd = line.slice(`${markerPrefix}READY:`.length) || consoleSession.cwd;
        } else if (line.startsWith(`${markerPrefix}END:`)) {
            const payload = line.slice(`${markerPrefix}END:`.length);
            const separatorIndex = payload.indexOf(':');
            if (separatorIndex !== -1) {
                const exitCode = Number.parseInt(payload.slice(0, separatorIndex), 10);
                const cwd = payload.slice(separatorIndex + 1);
                consoleSession.lastExitCode = Number.isNaN(exitCode) ? null : exitCode;
                consoleSession.cwd = cwd || consoleSession.cwd;
            }
            consoleSession.busy = false;
        } else {
            appendConsoleOutput(consoleSession, `${line}\n`);
        }

        buffer = buffer.slice(newlineIndex + 1);
        newlineIndex = buffer.indexOf('\n');
    }

    consoleSession[bufferKey] = buffer;
}

async function createConsoleSession(instanceName, ownerToken) {
    const config = await readResolvedInstanceConfig(instanceName);
    const runningContainers = await getRunningContainers();
    const containerName = getWorkspaceContainerName(instanceName);

    if (!runningContainers.has(containerName)) {
        throw new Error(`L'instance '${instanceName}' n'est pas en cours d'exécution.`);
    }

    for (const existingConsoleSession of consoleSessions.values()) {
        if (existingConsoleSession.ownerToken === ownerToken && existingConsoleSession.instanceName === instanceName) {
            closeConsoleSession(existingConsoleSession);
        }
    }

    const workspaceDir = getWorkspaceDirectory(config);
    const sessionId = crypto.randomUUID();
    const marker = `__OCOMPOSE_CONSOLE_${sessionId}__`;
    const consoleProcess = execFile('docker', [
        'exec',
        '-i',
        containerName,
        'bash',
        '-lc',
        `cd ${JSON.stringify(workspaceDir)} || exit 1; printf '${marker}:READY:%s\\n' "$PWD"; while IFS= read -r line; do if [ "$line" = '__OCOMPOSE_EXIT__' ]; then exit 0; fi; eval "$line"; status=$?; printf '${marker}:END:%s:%s\\n' "$status" "$PWD"; done`,
    ], {
        cwd: PROJECT_DIR,
        maxBuffer: 1024 * 1024 * 4,
    });

    const consoleSession = {
        id: sessionId,
        ownerToken,
        instanceName,
        marker,
        process: consoleProcess,
        output: '',
        baseCursor: 0,
        stdoutBuffer: '',
        stderrBuffer: '',
        cwd: workspaceDir,
        busy: false,
        closed: false,
        lastExitCode: null,
        lastActivityAt: Date.now(),
    };

    consoleProcess.stdout.setEncoding('utf8');
    consoleProcess.stderr.setEncoding('utf8');

    consoleProcess.stdout.on('data', (chunk) => {
        touchConsoleSession(consoleSession);
        consoleSession.stdoutBuffer += chunk;
        flushConsoleStream(consoleSession, 'stdout');
    });

    consoleProcess.stderr.on('data', (chunk) => {
        touchConsoleSession(consoleSession);
        consoleSession.stderrBuffer += chunk;
        flushConsoleStream(consoleSession, 'stderr');
    });

    consoleProcess.on('exit', () => {
        flushConsoleStream(consoleSession, 'stdout');
        flushConsoleStream(consoleSession, 'stderr');
        consoleSession.closed = true;
        consoleSession.busy = false;
    });

    consoleProcess.on('error', (error) => {
        appendConsoleOutput(consoleSession, `${error.message}\n`);
        consoleSession.closed = true;
        consoleSession.busy = false;
    });

    consoleSessions.set(sessionId, consoleSession);
    return consoleSession;
}

function validateInstanceName(instanceName) {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(instanceName || '')) {
        throw new Error('Les noms d\'instance ne peuvent contenir que des lettres, chiffres, tirets et underscores.');
    }
}

function sanitizeConfig(inputConfig) {
    const allowedKeys = new Set([
        'WORKSPACE_USER',
        'WORKSPACE_UID',
        'WORKSPACE_GID',
        'WORKSPACE_SHELL',
        'GIT_REPO',
        'GIT_BRANCH',
        'GIT_HTTP_USERNAME',
        'GIT_HTTP_PASSWORD',
        'PHP_ENABLED',
        'PHP_VERSION',
        'PHP_EXTENSIONS',
        'APP_PORT',
        'APP_BASE_URL',
        'NGINX_DOCUMENT_ROOT',
        'MYSQL_ENABLED',
        'MYSQL_VERSION',
        'MYSQL_ROOT_PASSWORD',
        'MYSQL_DATABASE',
        'MYSQL_USER',
        'MYSQL_PASSWORD',
        'MYSQL_PORT',
        'MYSQL_SEED_FILE',
        'MYSQL_RESEED_ON_STARTUP',
        'PHPMYADMIN_ENABLED',
        'PHPMYADMIN_PORT',
        'WORKSPACE_SSH_PORT',
    ]);

    const output = {};
    for (const [key, value] of Object.entries(inputConfig || {})) {
        if (allowedKeys.has(key)) {
            output[key] = normalizeValue(value);
        }
    }

    return output;
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

async function runWorkspaceCommand(instanceName, command) {
    const normalizedCommand = normalizeValue(command);
    if (!normalizedCommand) {
        throw new Error('Une commande est requise.');
    }

    const config = await readResolvedInstanceConfig(instanceName);
    const runningContainers = await getRunningContainers();
    const containerName = getWorkspaceContainerName(instanceName);

    if (!runningContainers.has(containerName)) {
        throw new Error(`L'instance '${instanceName}' n'est pas en cours d'exécution.`);
    }

    const workspaceDir = getWorkspaceDirectory(config);

    try {
        const result = await execFileAsync('docker', [
            'exec',
            '-i',
            '-w',
            workspaceDir,
            containerName,
            'bash',
            '-lc',
            normalizedCommand,
        ], {
            cwd: PROJECT_DIR,
            maxBuffer: 1024 * 1024 * 4,
        });

        return {
            ok: true,
            exitCode: 0,
            stdout: result.stdout || '',
            stderr: result.stderr || '',
            cwd: workspaceDir,
        };
    } catch (error) {
        if (error.code === 'ENOENT') {
            throw new Error('La CLI Docker n\'est pas disponible sur l\'hôte.');
        }

        if (typeof error.code === 'number') {
            return {
                ok: false,
                exitCode: error.code,
                stdout: error.stdout || '',
                stderr: error.stderr || '',
                cwd: workspaceDir,
            };
        }

        throw error;
    }
}

function getConsoleSnapshot(consoleSession, cursorInput) {
    const requestedCursor = Number.parseInt(String(cursorInput || consoleSession.baseCursor), 10);
    const cursor = Number.isNaN(requestedCursor)
        ? consoleSession.baseCursor
        : Math.max(requestedCursor, consoleSession.baseCursor);
    const sliceStart = cursor - consoleSession.baseCursor;
    const output = consoleSession.output.slice(sliceStart);

    return {
        sessionId: consoleSession.id,
        cursor: consoleSession.baseCursor + consoleSession.output.length,
        output,
        cwd: consoleSession.cwd,
        busy: consoleSession.busy,
        closed: consoleSession.closed,
        lastExitCode: consoleSession.lastExitCode,
    };
}

async function getInstance(instanceName, accessHost = 'localhost') {
    const [config, runningContainers] = await Promise.all([
        readResolvedInstanceConfig(instanceName),
        getRunningContainers(),
    ]);

    return buildInstanceSummary(instanceName, config, runningContainers, accessHost);
}

async function listInstances(accessHost = 'localhost') {
    const [instanceNames, runningContainers] = await Promise.all([
        listInstanceNames(),
        getRunningContainers(),
    ]);

    const instances = [];
    for (const instanceName of instanceNames) {
        try {
            const config = await readResolvedInstanceConfig(instanceName);
            instances.push(buildInstanceSummary(instanceName, config, runningContainers, accessHost));
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

async function serveStaticFile(response, relativePath) {
    const resolvedPath = path.resolve(PUBLIC_DIR, relativePath);
    if (!resolvedPath.startsWith(PUBLIC_DIR)) {
        send(response, 403, 'Forbidden');
        return;
    }

    try {
        const content = await fs.readFile(resolvedPath);
        send(response, 200, content, MIME_TYPES[path.extname(resolvedPath).toLowerCase()] || 'application/octet-stream');
    } catch (error) {
        if (error.code === 'ENOENT') {
            send(response, 404, 'Not found');
            return;
        }

        throw error;
    }
}

function isPublicAsset(urlPath) {
    return urlPath === '/login' || urlPath === '/login.js' || urlPath === '/styles.css' || urlPath === '/api/auth/login';
}

function requireSession(request, response, url) {
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

async function handleAuthApi(request, response, url) {
    if (request.method === 'POST' && url.pathname === '/api/auth/login') {
        const body = await readJsonBody(request);
        const username = normalizeValue(body.username);
        const password = normalizeValue(body.password);

        if (!AUTH_PASSWORD) {
            sendJson(response, 500, { error: 'UI authentication is not configured.' });
            return true;
        }

        if (!timingSafeEquals(username, AUTH_USERNAME) || !timingSafeEquals(password, AUTH_PASSWORD)) {
            sendJson(response, 401, { error: 'Invalid username or password.' });
            return true;
        }

        const token = createSession(username);
        setSessionCookie(response, token);
        sendJson(response, 200, { ok: true, username });
        return true;
    }

    if (request.method === 'POST' && url.pathname === '/api/auth/logout') {
        const session = getSession(request);
        if (session) {
            sessions.delete(session.token);
        }
        clearSessionCookie(response);
        sendJson(response, 200, { ok: true });
        return true;
    }

    if (request.method === 'GET' && url.pathname === '/api/auth/session') {
        const session = getSession(request);
        if (!session) {
            sendJson(response, 401, { error: 'Authentication required.' });
            return true;
        }

        sendJson(response, 200, { ok: true, username: session.username });
        return true;
    }

    return false;
}

async function handleInstanceApi(request, response, url) {
    const pathParts = url.pathname.split('/').filter(Boolean);
    const accessHost = getRequestHostname(request);
    cleanupConsoleSessions();

    if (request.method === 'GET' && url.pathname === '/api/db-files') {
        sendJson(response, 200, { files: await listDbFiles() });
        return true;
    }

    if (request.method === 'GET' && url.pathname === '/api/instances') {
        sendJson(response, 200, { instances: await listInstances(accessHost) });
        return true;
    }

    if (request.method === 'POST' && url.pathname === '/api/instances') {
        const body = await readJsonBody(request);
        const instanceName = normalizeValue(body.name);
        validateInstanceName(instanceName);
        await runOcompose([instanceName, 'init', '--yes']);
        sendJson(response, 201, { instance: await getInstance(instanceName, accessHost) });
        return true;
    }

    if (pathParts.length === 3 && pathParts[0] === 'api' && pathParts[1] === 'instances') {
        const instanceName = pathParts[2];
        validateInstanceName(instanceName);

        if (request.method === 'GET') {
            sendJson(response, 200, { instance: await getInstance(instanceName, accessHost) });
            return true;
        }

        if (request.method === 'PUT') {
            const body = await readJsonBody(request);
            await writeInstanceConfig(instanceName, sanitizeConfig(body.config));
            sendJson(response, 200, { instance: await getInstance(instanceName, accessHost) });
            return true;
        }
    }

    if (pathParts.length === 5 && pathParts[0] === 'api' && pathParts[1] === 'instances' && pathParts[3] === 'actions') {
        const instanceName = pathParts[2];
        const action = pathParts[4];
        validateInstanceName(instanceName);

        const commands = {
            up: [instanceName, 'up'],
            down: [instanceName, 'down'],
            restart: [instanceName, 'restart'],
            destroy: [instanceName, 'destroy', '--yes'],
        };

        if (!commands[action]) {
            sendJson(response, 400, { error: 'Unsupported action.' });
            return true;
        }

        const result = await runOcompose(commands[action]);
        if (action === 'destroy') {
            sendJson(response, 200, { ok: true, output: result.stdout || result.stderr || 'Destroyed.' });
            return true;
        }

        sendJson(response, 200, {
            ok: true,
            output: result.stdout || result.stderr || '',
            instance: await getInstance(instanceName, accessHost),
        });
        return true;
    }

    if (pathParts.length === 5 && pathParts[0] === 'api' && pathParts[1] === 'instances' && pathParts[3] === 'console' && pathParts[4] === 'execute') {
        const instanceName = pathParts[2];
        validateInstanceName(instanceName);

        if (request.method !== 'POST') {
            sendJson(response, 405, { error: 'Method not allowed.' });
            return true;
        }

        const body = await readJsonBody(request);
        const command = normalizeValue(body.command);
        if (!command) {
            sendJson(response, 400, { error: 'A command is required.' });
            return true;
        }

        const result = await runWorkspaceCommand(instanceName, command);
        sendJson(response, 200, result);
        return true;
    }

    if (pathParts.length === 5 && pathParts[0] === 'api' && pathParts[1] === 'instances' && pathParts[3] === 'console' && pathParts[4] === 'session') {
        const instanceName = pathParts[2];
        const session = getSession(request);
        validateInstanceName(instanceName);

        if (!session) {
            sendJson(response, 401, { error: 'Authentication required.' });
            return true;
        }

        if (request.method === 'POST') {
            const consoleSession = await createConsoleSession(instanceName, session.token);
            sendJson(response, 201, getConsoleSnapshot(consoleSession));
            return true;
        }

        if (request.method === 'GET') {
            const sessionId = normalizeValue(url.searchParams.get('sessionId'));
            const consoleSession = getConsoleSession(sessionId, session.token, instanceName);
            if (!consoleSession) {
                sendJson(response, 404, { error: 'Console session not found.' });
                return true;
            }

            sendJson(response, 200, getConsoleSnapshot(consoleSession, url.searchParams.get('cursor')));
            return true;
        }

        if (request.method === 'DELETE') {
            const sessionId = normalizeValue(url.searchParams.get('sessionId'));
            const consoleSession = getConsoleSession(sessionId, session.token, instanceName);
            if (!consoleSession) {
                sendJson(response, 404, { error: 'Console session not found.' });
                return true;
            }

            closeConsoleSession(consoleSession);
            sendJson(response, 200, { ok: true });
            return true;
        }
    }

    if (pathParts.length === 5 && pathParts[0] === 'api' && pathParts[1] === 'instances' && pathParts[3] === 'console' && pathParts[4] === 'input') {
        const instanceName = pathParts[2];
        const session = getSession(request);
        validateInstanceName(instanceName);

        if (!session) {
            sendJson(response, 401, { error: 'Authentication required.' });
            return true;
        }

        if (request.method !== 'POST') {
            sendJson(response, 405, { error: 'Method not allowed.' });
            return true;
        }

        const body = await readJsonBody(request);
        const sessionId = normalizeValue(body.sessionId);
        const input = String(body.input || '');
        const consoleSession = getConsoleSession(sessionId, session.token, instanceName);

        if (!consoleSession) {
            sendJson(response, 404, { error: 'Console session not found.' });
            return true;
        }

        if (consoleSession.closed) {
            sendJson(response, 409, { error: 'Console session is closed.' });
            return true;
        }

        consoleSession.busy = true;
        touchConsoleSession(consoleSession);
        consoleSession.process.stdin.write(`${input.replace(/\r?\n/g, ' ')}\n`);
        sendJson(response, 202, { ok: true, cwd: consoleSession.cwd });
        return true;
    }

    return false;
}

const server = http.createServer(async (request, response) => {
    try {
        const url = new URL(request.url, `http://${request.headers.host || `localhost:${PORT}`}`);

        if (await handleAuthApi(request, response, url)) {
            return;
        }

        if (!isPublicAsset(url.pathname)) {
            const session = requireSession(request, response, url);
            if (!session) {
                return;
            }
        }

        if (url.pathname === '/login' && getSession(request)) {
            redirect(response, '/');
            return;
        }

        if (url.pathname.startsWith('/api/')) {
            if (await handleInstanceApi(request, response, url)) {
                return;
            }

            sendJson(response, 404, { error: 'Not found.' });
            return;
        }

        const assetPath = url.pathname === '/'
            ? 'index.html'
            : url.pathname === '/login'
                ? 'login.html'
                : url.pathname.slice(1);

        await serveStaticFile(response, assetPath);
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
