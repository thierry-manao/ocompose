const http = require('http');
const fs = require('fs/promises');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);

const PROJECT_DIR = path.resolve(__dirname, '..');
const INSTANCES_DIR = path.join(PROJECT_DIR, 'instances');
const TEMPLATE_PATH = path.join(PROJECT_DIR, '.env.example');
const PUBLIC_DIR = path.join(__dirname, 'public');
const SCRIPT_PATH = path.join(PROJECT_DIR, 'scripts', 'ocompose.sh');
const PORT = Number.parseInt(process.env.OCOMPOSE_UI_PORT || '8787', 10);

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
        readInstanceConfig(instanceName),
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
            const config = await readInstanceConfig(instanceName);
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

        if (url.pathname.startsWith('/api/')) {
            await handleApi(request, response, url);
            return;
        }

        const relativePath = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
        await serveStaticFile(response, relativePath);
    } catch (error) {
        const statusCode = error.code === 'ENOENT' ? 404 : 500;
        sendJson(response, statusCode, { error: error.message || 'Unexpected server error.' });
    }
});

server.listen(PORT, () => {
    console.log(`ocompose web UI listening on http://localhost:${PORT}`);
});