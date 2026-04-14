const state = {
    instances: [],
    selectedInstanceName: null,
    activeView: 'dashboard',
    settingsTab: 'stack',
    consoleSessionId: null,
    consoleCursor: 0,
    consoleInstanceName: null,
    consolePollTimer: null,
    pendingActions: {},
};

const form = document.querySelector('#config-form');
const createForm = document.querySelector('#create-form');
const instanceList = document.querySelector('#instance-list');
const instanceTitle = document.querySelector('#instance-title');
const instanceSubtitle = document.querySelector('#instance-subtitle');
const statusChip = document.querySelector('#status-chip');
const messageBar = document.querySelector('#message-bar');
const heroAppPort = document.querySelector('#hero-app-port');
const heroDbPort = document.querySelector('#hero-db-port');
const refreshButton = document.querySelector('#refresh-button');
const logoutButton = document.querySelector('#logout-button');
const actionButtons = Array.from(document.querySelectorAll('[data-action]'));
const sectionNavButtons = Array.from(document.querySelectorAll('[data-view]'));
const viewPanels = Array.from(document.querySelectorAll('[data-view-panel]'));
const settingsTabButtons = Array.from(document.querySelectorAll('[data-settings-tab]'));
const settingsTabPanels = Array.from(document.querySelectorAll('[data-settings-tab-panel]'));
const dashboardInstanceGrid = document.querySelector('#dashboard-instance-grid');
const sidebarInstanceList = document.querySelector('#sidebar-instance-list');
const consoleForm = document.querySelector('#console-form');
const consoleSurface = document.querySelector('#console-surface');
const consoleCommand = document.querySelector('#console-command');
const consolePrompt = document.querySelector('#console-prompt');
const consoleClearButton = document.querySelector('#console-clear-button');
const consoleOutput = document.querySelector('#console-output');
const consoleSubtitle = document.querySelector('#console-subtitle');
const consoleCwd = document.querySelector('#console-cwd');
const consoleStatus = document.querySelector('#console-status');
const consoleShortcutButtons = Array.from(document.querySelectorAll('[data-console-command]'));
const filesContainer = document.querySelector('#files-container');

const fieldNames = [
    'WORKSPACE_USER',
    'WORKSPACE_UID',
    'WORKSPACE_GID',
    'WORKSPACE_SHELL',
    'GIT_REPO',
    'GIT_BRANCH',
    'GIT_HTTP_USERNAME',
    'GIT_HTTP_PASSWORD',
    'APP_RUNTIME',
    'APP_BASE_URL',
    'PHP_VERSION',
    'PHP_EXTENSIONS',
    'NODE_VERSION',
    'NODE_COMMAND',
    'PYTHON_VERSION',
    'PYTHON_COMMAND',
    'VHOSTS',
    'DB_HOST',
    'DB_PORT',
    'DB_DATABASE',
    'DB_USER',
    'DB_PASSWORD',
    'DB_EXTERNAL_NETWORK',
    'REDIS_ENABLED',
    'REDIS_VERSION',
    'REDIS_PORT',
    'WORKSPACE_SSH_PORT',
    'CI3_ENABLED',
    'CI3_EXTRA_CONSTANTS',
    'CI3_APP_ROOT',
    'CI3_SESSION_SAVE_PATH',
    'CI3_BASE_URL',
    'CI3_AUTH_URL',
];

// ── Runtime field visibility ──

const runtimeSelect = form.elements.namedItem('APP_RUNTIME');
const runtimeFields = Array.from(document.querySelectorAll('.runtime-field'));

function updateRuntimeFields(runtime) {
    runtimeFields.forEach((field) => {
        const group = field.dataset.runtimeGroup;
        field.style.display = group === runtime ? '' : 'none';
    });
}

if (runtimeSelect) {
    runtimeSelect.addEventListener('change', () => {
        updateRuntimeFields(runtimeSelect.value);
    });
}

// ── db-docker-server integration ──

const dbserverState = {
    instances: [],
    connected: false,
};

const dbserverInstanceSelect = document.querySelector('#dbserver-instance-select');
const dbserverDatabaseSelect = document.querySelector('#dbserver-database-select');
const dbserverStatusIndicator = document.querySelector('#dbserver-status-indicator');
const dbserverStatusText = document.querySelector('#dbserver-status-text');
const dbserverRefreshButton = document.querySelector('#dbserver-refresh');
const dbserverInstancesDetail = document.querySelector('#dbserver-instances-detail');
const dbserverInstancesList = document.querySelector('#dbserver-instances-list');

async function loadDbserverInstances() {
    try {
        const payload = await apiRequest('/api/dbserver/instances');
        dbserverState.instances = Array.isArray(payload.instances) ? payload.instances : [];
        dbserverState.connected = true;
        renderDbserverStatus();
        renderDbserverInstanceSelect();
        renderDbserverInstancesDetail();
    } catch (error) {
        dbserverState.instances = [];
        dbserverState.connected = false;
        renderDbserverStatus();
        renderDbserverInstanceSelect();
        renderDbserverInstancesDetail();
    }
}

function renderDbserverStatus() {
    if (dbserverState.connected && dbserverState.instances.length > 0) {
        const running = dbserverState.instances.filter((i) => i.running);
        dbserverStatusIndicator.textContent = running.length > 0 ? 'connecté' : 'arrêté';
        dbserverStatusIndicator.className = `status-chip ${running.length > 0 ? 'running' : 'stopped'}`;
        dbserverStatusText.textContent = `${dbserverState.instances.length} instance(s), ${running.length} active(s)`;
    } else if (dbserverState.connected) {
        dbserverStatusIndicator.textContent = 'vide';
        dbserverStatusIndicator.className = 'status-chip idle';
        dbserverStatusText.textContent = 'db-docker-server connecté mais aucune instance trouvée.';
    } else {
        dbserverStatusIndicator.textContent = 'hors ligne';
        dbserverStatusIndicator.className = 'status-chip stopped';
        dbserverStatusText.textContent = 'Impossible de joindre db-docker-server. Est-il démarré ?';
    }
}

function renderDbserverInstanceSelect() {
    if (!dbserverInstanceSelect) return;

    const currentDbPort = form.elements.namedItem('DB_PORT')?.value || '';

    if (!dbserverState.connected || dbserverState.instances.length === 0) {
        dbserverInstanceSelect.innerHTML = '<option value="">Aucune instance disponible</option>';
        dbserverDatabaseSelect.innerHTML = '<option value="">-</option>';
        return;
    }

    const options = ['<option value="">Sélectionnez une instance</option>'];
    dbserverState.instances.forEach((inst) => {
        const port = inst.config?.DB_PORT || '?';
        const engine = inst.config?.DB_ENGINE || '?';
        const statusLabel = inst.running ? '●' : '○';
        const selected = currentDbPort && port === currentDbPort ? ' selected' : '';
        options.push(`<option value="${inst.name}" data-port="${port}" data-engine="${engine}"${selected}>${statusLabel} ${inst.name} (${engine} :${port})</option>`);
    });
    dbserverInstanceSelect.innerHTML = options.join('');

    // If a current port matches, auto-select and populate databases
    if (dbserverInstanceSelect.value) {
        onDbserverInstanceSelected(dbserverInstanceSelect.value);
    }
}

function onDbserverInstanceSelected(instanceName) {
    const inst = dbserverState.instances.find((i) => i.name === instanceName);
    if (!inst) {
        dbserverDatabaseSelect.innerHTML = '<option value="">Sélectionnez d\'abord une instance</option>';
        return;
    }

    // Update port field to match selected instance
    const portField = form.elements.namedItem('DB_PORT');
    if (portField && inst.config?.DB_PORT) {
        portField.value = inst.config.DB_PORT;
    }

    // Populate databases from seed history
    const currentDb = form.elements.namedItem('DB_DATABASE')?.value || '';
    const databases = new Set();
    if (inst.seedHistory) {
        inst.seedHistory.forEach((entry) => {
            if (entry.database) databases.add(entry.database);
        });
    }
    if (inst.config?.DB_DATABASE) {
        databases.add(inst.config.DB_DATABASE);
    }

    const dbOptions = ['<option value="">Sélectionnez une base de données</option>'];
    databases.forEach((db) => {
        const selected = db === currentDb ? ' selected' : '';
        dbOptions.push(`<option value="${db}"${selected}>${db}</option>`);
    });
    // Allow custom entry
    if (currentDb && !databases.has(currentDb)) {
        dbOptions.push(`<option value="${currentDb}" selected>${currentDb} (personnalisé)</option>`);
    }
    dbserverDatabaseSelect.innerHTML = dbOptions.join('');
}

function renderDbserverInstancesDetail() {
    if (!dbserverState.connected || dbserverState.instances.length === 0) {
        dbserverInstancesList.innerHTML = `
            <div class="text-center text-secondary py-4">
                <i class="bi bi-inbox" style="font-size: 2rem;"></i>
                <p class="mt-2 mb-0 small">Aucune instance détectée</p>
            </div>
        `;
        return;
    }

    dbserverInstancesList.innerHTML = dbserverState.instances.map((inst) => {
        const engine = inst.config?.DB_ENGINE || '?';
        const port = inst.config?.DB_PORT || '?';
        const dbs = inst.seedHistory ? [...new Set(inst.seedHistory.map((s) => s.database).filter(Boolean))].join(', ') : '-';
        const statusClass = inst.running ? 'running' : 'stopped';
        return `
            <div class="card-shell p-3">
                <div class="d-flex align-items-center gap-2 mb-2">
                    <strong>${inst.name}</strong>
                    <span class="status-chip ${statusClass}">${inst.running ? 'actif' : 'arrêté'}</span>
                </div>
                <small class="text-secondary d-block">Moteur: ${engine} | Port: ${port}</small>
                <small class="text-secondary d-block">Bases: ${dbs || 'aucune'}</small>
            </div>
        `;
    }).join('');
}

if (dbserverInstanceSelect) {
    dbserverInstanceSelect.addEventListener('change', (event) => {
        onDbserverInstanceSelected(event.target.value);
    });
}

if (dbserverDatabaseSelect) {
    dbserverDatabaseSelect.addEventListener('change', (event) => {
        const dbField = form.elements.namedItem('DB_DATABASE');
        if (dbField) dbField.value = event.target.value;
    });
}

if (dbserverRefreshButton) {
    dbserverRefreshButton.addEventListener('click', () => {
        loadDbserverInstances();
    });
}

// ── Test DB connection ──

const testDbConnectionButton = document.querySelector('#test-db-connection');
const testDbConnectionResult = document.querySelector('#test-db-connection-result');

if (testDbConnectionButton) {
    testDbConnectionButton.addEventListener('click', async () => {
        const host = form.elements.namedItem('DB_HOST')?.value || '';
        const port = form.elements.namedItem('DB_PORT')?.value || '';
        const user = form.elements.namedItem('DB_USER')?.value || '';
        const password = form.elements.namedItem('DB_PASSWORD')?.value || '';
        const database = form.elements.namedItem('DB_DATABASE')?.value || '';

        testDbConnectionResult.textContent = 'Test en cours...';
        testDbConnectionResult.className = 'ms-3 small text-secondary';
        testDbConnectionButton.disabled = true;

        try {
            const result = await apiRequest('/api/test-db-connection', {
                method: 'POST',
                body: JSON.stringify({ host, port, user, password, database }),
            });

            if (result.ok) {
                testDbConnectionResult.textContent = result.message;
                testDbConnectionResult.className = 'ms-3 small text-success';
            } else {
                testDbConnectionResult.textContent = result.error;
                testDbConnectionResult.className = 'ms-3 small text-danger';
            }
        } catch (error) {
            testDbConnectionResult.textContent = 'Erreur lors du test de connexion.';
            testDbConnectionResult.className = 'ms-3 small text-danger';
        } finally {
            testDbConnectionButton.disabled = false;
        }
    });
}

function setMessage(text, isError = false) {
    messageBar.textContent = text;
    messageBar.classList.toggle('error', isError);
}

function setConsoleOutput(text) {
    consoleOutput.textContent = text;
    consoleOutput.scrollTop = consoleOutput.scrollHeight;
}

function appendConsoleOutput(text) {
    const nextText = consoleOutput.textContent.trim()
        ? `${consoleOutput.textContent.replace(/\s+$/g, '')}\n\n${text}`
        : text;
    setConsoleOutput(nextText);
}

function setConsoleStatus(text) {
    consoleStatus.textContent = text;
}

function setSettingsTab(tabName) {
    state.settingsTab = tabName;

    settingsTabButtons.forEach((button) => {
        button.classList.toggle('active', button.dataset.settingsTab === tabName);
    });

    settingsTabPanels.forEach((panel) => {
        panel.classList.toggle('is-active', panel.dataset.settingsTabPanel === tabName);
    });

    if (tabName === 'database') {
        loadDbserverInstances();
    }
}

function setActiveView(viewName) {
    state.activeView = viewName;

    sectionNavButtons.forEach((button) => {
        button.classList.toggle('active', button.dataset.view === viewName);
    });

    viewPanels.forEach((panel) => {
        panel.classList.toggle('is-active', panel.dataset.viewPanel === viewName);
    });

    if (viewName === 'shell') {
        updateConsoleState(getSelectedInstance());
        consoleCommand.focus();
    }

    if (viewName === 'files') {
        loadInstanceFiles();
    }
}

function updateConsolePrompt(instance) {
    consolePrompt.textContent = instance ? `${instance.name}$` : '$';
}

async function apiRequest(path, options = {}) {
    const response = await fetch(path, {
        headers: {
            'Content-Type': 'application/json',
            ...(options.headers || {}),
        },
        credentials: 'same-origin',
        ...options,
    });

    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
        throw new Error(payload.error || 'La requête a échoué.');
    }

    return payload;
}

function getSelectedInstance() {
    return state.instances.find((instance) => instance.name === state.selectedInstanceName) || null;
}

function setInstancePending(instanceName, action) {
    state.pendingActions[instanceName] = action;
    updateAllActionButtons();
}

function clearInstancePending(instanceName) {
    delete state.pendingActions[instanceName];
    updateAllActionButtons();
}

function updateAllActionButtons() {
    // Update sidebar action buttons (settings view)
    actionButtons.forEach((button) => {
        const instance = getSelectedInstance();
        if (!instance) {
            return;
        }
        const pending = state.pendingActions[instance.name];
        const action = button.dataset.action;
        button.disabled = !!pending;

        if (pending && pending === action) {
            if (!button.querySelector('.spinner-border')) {
                const spinner = document.createElement('span');
                spinner.className = 'spinner-border spinner-border-sm me-2';
                spinner.setAttribute('role', 'status');
                button.prepend(spinner);
            }
        } else {
            const spinner = button.querySelector('.spinner-border');
            if (spinner) {
                spinner.remove();
            }
        }
    });

    // Update dashboard and instance list card buttons
    document.querySelectorAll('[data-dashboard-action]').forEach((button) => {
        const instanceName = button.dataset.dashboardInstance;
        const action = button.dataset.dashboardAction;
        const pending = state.pendingActions[instanceName];
        button.disabled = !!pending;

        if (pending && pending === action) {
            if (!button.querySelector('.spinner-border')) {
                const spinner = document.createElement('span');
                spinner.className = 'spinner-border spinner-border-sm me-1';
                spinner.setAttribute('role', 'status');
                button.prepend(spinner);
            }
        } else {
            const spinner = button.querySelector('.spinner-border');
            if (spinner) {
                spinner.remove();
            }
        }
    });
}

async function runInstanceAction(instanceName, action) {
    const instance = state.instances.find((entry) => entry.name === instanceName);
    if (!instance) {
        setMessage('Instance introuvable.', true);
        return;
    }

    if (state.pendingActions[instanceName]) {
        setMessage(`Une opération est déjà en cours sur ${instanceName}.`, true);
        return;
    }

    if (action === 'destroy' && !window.confirm(`Détruire ${instance.name} et supprimer ses données ?`)) {
        return;
    }

    try {
        setMessage(`${action} ${instance.name}...`);
        setInstancePending(instanceName, action);
        await apiRequest(`/api/instances/${instance.name}/actions/${action}`, {
            method: 'POST',
        });

        if (action === 'destroy') {
            clearInstancePending(instanceName);
            await refreshInstances(false);
            setMessage(`${instance.name} détruit.`);
            return;
        }

        clearInstancePending(instanceName);
        await refreshInstances();
        setMessage(`${action} terminé pour ${instance.name}.`);
    } catch (error) {
        clearInstancePending(instanceName);
        setMessage(error.message, true);
    }
}

function getAccessHostname() {
    return window.location.hostname || 'localhost';
}

function buildHttpAccessUrl(port) {
    const normalizedPort = String(port || '').trim();
    if (!normalizedPort) {
        return null;
    }

    return `http://${getAccessHostname()}:${normalizedPort}`;
}

function buildSshTarget(port) {
    const normalizedPort = String(port || '').trim();
    if (!normalizedPort) {
        return null;
    }

    return `${getAccessHostname()}:${normalizedPort}`;
}

function parseVhostUrls(instance) {
    const vhosts = String(instance?.config?.VHOSTS || '').trim();
    if (!vhosts) {
        return [];
    }

    return vhosts.split(',').map((entry) => entry.trim()).filter(Boolean).map((entry) => {
        const [port, docroot] = entry.split(':');
        const label = docroot || '/';
        return {
            url: `http://${getAccessHostname()}:${port}`,
            label: label === '/' ? `app :${port}` : `${docroot} :${port}`,
        };
    });
}

function updateEndpoints(instance) {
    heroAppPort.textContent = instance?.config?.VHOSTS || '-';
    heroDbPort.textContent = instance?.config?.DB_PORT || '-';
}

function escapeHtml(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function loadInstanceFiles() {
    const instance = getSelectedInstance();
    if (!instance) {
        filesContainer.innerHTML = '<p class="text-secondary">Sélectionnez une instance pour afficher ses fichiers de configuration.</p>';
        return;
    }

    try {
        filesContainer.innerHTML = '<p class="text-secondary">Chargement…</p>';
        const payload = await apiRequest(`/api/instances/${instance.name}/files`);
        const files = payload.files || [];

        if (files.length === 0) {
            filesContainer.innerHTML = '<p class="text-secondary">Aucun fichier de configuration trouvé.</p>';
            return;
        }

        filesContainer.innerHTML = files.map((file) => `
            <div class="config-file-block mb-4">
                <div class="config-file-header">
                    <i class="bi bi-file-earmark-text me-2"></i>
                    <strong>${escapeHtml(file.name)}</strong>
                </div>
                <pre class="config-file-content">${escapeHtml(file.content)}</pre>
            </div>
        `).join('');
    } catch (error) {
        filesContainer.innerHTML = `<p class="text-danger">${escapeHtml(error.message)}</p>`;
    }
}

function setConsoleEnabled(enabled) {
    consoleCommand.disabled = !enabled;
    consoleClearButton.disabled = !enabled;
    consoleShortcutButtons.forEach((button) => {
        button.disabled = !enabled;
    });
}

function stopConsolePolling() {
    if (state.consolePollTimer) {
        window.clearTimeout(state.consolePollTimer);
        state.consolePollTimer = null;
    }
}

async function closeConsoleSession() {
    if (!state.consoleSessionId || !state.consoleInstanceName) {
        state.consoleSessionId = null;
        state.consoleCursor = 0;
        state.consoleInstanceName = null;
        return;
    }

    stopConsolePolling();

    try {
        await apiRequest(`/api/instances/${state.consoleInstanceName}/console/session?sessionId=${encodeURIComponent(state.consoleSessionId)}`, {
            method: 'DELETE',
        });
    } catch (error) {
        // Ignore cleanup failures when switching instances.
    }

    state.consoleSessionId = null;
    state.consoleCursor = 0;
    state.consoleInstanceName = null;
}

async function pollConsoleOutput() {
    const instanceName = state.consoleInstanceName;
    const sessionId = state.consoleSessionId;

    if (!instanceName || !sessionId) {
        return;
    }

    try {
        const payload = await apiRequest(`/api/instances/${instanceName}/console/session?sessionId=${encodeURIComponent(sessionId)}&cursor=${state.consoleCursor}`);

        if (state.consoleSessionId !== payload.sessionId) {
            return;
        }

        if (payload.output) {
            appendConsoleOutput(payload.output.replace(/\s+$/g, ''));
        }

        state.consoleCursor = payload.cursor;
        consoleCwd.textContent = `cwd: ${payload.cwd || 'unavailable'}`;
        setConsoleStatus(payload.closed ? 'session: fermée' : payload.busy ? 'session: occupée' : 'session: prête');

        if (!payload.closed && state.consoleSessionId === payload.sessionId) {
            state.consolePollTimer = window.setTimeout(pollConsoleOutput, 800);
            return;
        }

        state.consoleSessionId = null;
    } catch (error) {
        setConsoleStatus('session: hors ligne');
        setMessage(error.message, true);
    }
}

async function ensureConsoleSession(instance) {
    if (!instance || instance.status !== 'running') {
        if (state.consoleSessionId) {
            await closeConsoleSession();
        }
        return;
    }

    if (state.consoleSessionId && state.consoleInstanceName === instance.name) {
        stopConsolePolling();
        state.consolePollTimer = window.setTimeout(pollConsoleOutput, 150);
        return;
    }

    if (state.consoleSessionId && state.consoleInstanceName !== instance.name) {
        await closeConsoleSession();
    }

    const payload = await apiRequest(`/api/instances/${instance.name}/console/session`, {
        method: 'POST',
    });

    state.consoleSessionId = payload.sessionId;
    state.consoleCursor = payload.cursor;
    state.consoleInstanceName = instance.name;
    setConsoleStatus('session: prête');
    consoleCwd.textContent = `cwd: ${payload.cwd || 'non disponible'}`;
    setConsoleOutput(`Connecté à ${instance.name}. L'état est préservé entre les commandes.`);
    stopConsolePolling();
    state.consolePollTimer = window.setTimeout(pollConsoleOutput, 800);
}

function updateConsoleState(instance) {
    updateConsolePrompt(instance);

    if (!instance) {
        stopConsolePolling();
        setConsoleEnabled(false);
        consoleSubtitle.textContent = 'Les commandes s\'exécutent à l\'intérieur du conteneur d\'espace de travail sélectionné depuis sa racine de projet.';
        consoleCwd.textContent = 'cwd: non disponible';
        setConsoleStatus('session: hors ligne');
        setConsoleOutput('Sélectionnez une instance en cours d\'exécution pour ouvrir sa console d\'espace de travail.');
        return;
    }

    const workspaceUser = instance.config?.WORKSPACE_USER || 'developer';
    const cwd = `/home/${workspaceUser}/workspace`;
    consoleCwd.textContent = `cwd: ${cwd}`;

    if (state.activeView !== 'shell') {
        return;
    }

    if (instance.status !== 'running') {
        stopConsolePolling();
        setConsoleEnabled(false);
        consoleSubtitle.textContent = 'Démarrez d\'abord l\'instance. Les commandes ne s\'exécutent que sur un conteneur d\'espace de travail actif.';
        setConsoleStatus('session: hors ligne');
        setConsoleOutput(`L'instance ${instance.name} est arrêtée. Démarrez-la pour utiliser la console web.`);
        return;
    }

    setConsoleEnabled(true);
    consoleSubtitle.textContent = `Les commandes s'exécutent dans ${instance.name}_workspace depuis ${cwd}.`;
    setConsoleStatus(state.consoleSessionId && state.consoleInstanceName === instance.name ? 'session: prête' : 'session: connexion en cours');

    if (!consoleOutput.dataset.instanceName || consoleOutput.dataset.instanceName !== instance.name) {
        setConsoleOutput(`Connexion à ${instance.name}...`);
    }

    consoleOutput.dataset.instanceName = instance.name;
    ensureConsoleSession(instance).catch((error) => {
        setConsoleStatus('session: hors ligne');
        setMessage(error.message, true);
        setConsoleOutput(error.message);
    });
}

function setFormEnabled(enabled) {
    Array.from(form.elements).forEach((element) => {
        element.disabled = !enabled;
    });
}

function fillForm(instance) {
    if (!instance) {
        form.reset();
        setFormEnabled(false);
        updateEndpoints(null);
        updateRuntimeFields('php');
        instanceTitle.textContent = 'Sélectionnez une instance';
        instanceSubtitle.textContent = 'Créez ou sélectionnez une instance pour déverrouiller la configuration. Jusque-là, l\'\u00e9diteur reste intentionnellement verrouillé.';
        statusChip.textContent = 'inactif';
        statusChip.className = 'status-chip idle';
        updateConsoleState(null);
        if (state.activeView === 'files') {
            loadInstanceFiles();
        }
        return;
    }

    setFormEnabled(true);
    fieldNames.forEach((fieldName) => {
        const element = form.elements.namedItem(fieldName);
        if (!element) {
            return;
        }

        if (element.type === 'checkbox') {
            element.checked = String(instance.config[fieldName]).toLowerCase() === 'true';
            return;
        }

        element.value = instance.config[fieldName] || '';
    });

    instanceTitle.textContent = instance.name;
    instanceSubtitle.textContent = 'Ces champs éditent le même fichier `.env` utilisé par le CLI et Docker Compose.';
    statusChip.textContent = instance.status;
    statusChip.className = `status-chip ${instance.status}`;
    updateEndpoints(instance);
    updateRuntimeFields(instance.config?.APP_RUNTIME || 'php');
    updateConsoleState(instance);
    if (state.activeView === 'files') {
        loadInstanceFiles();
    }
}

function renderInstances() {
    instanceList.innerHTML = '';
    renderSidebarInstances();

    if (state.instances.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'empty-state';
        empty.textContent = 'Pas encore d\'instances. Créez-en une pour commencer.';
        instanceList.appendChild(empty);
        fillForm(null);
        return;
    }

    state.instances.forEach((instance) => {
        const appUrls = parseVhostUrls(instance);

        const card = document.createElement('article');
        card.className = `dashboard-instance-card${instance.name === state.selectedInstanceName ? ' active' : ''}`;

        const appLinks = appUrls.map((entry) =>
            `<a class="btn btn-link p-0 dashboard-link-button" href="${entry.url}" target="_blank" rel="noreferrer">Ouvrir ${entry.label}</a>`
        ).join('');

        card.innerHTML = `
            <div class="dashboard-instance-card__head">
                <div>
                    <h3 class="dashboard-instance-card__title">${instance.name}</h3>
                    <p class="dashboard-instance-card__subtitle">${instance.status === 'running' ? 'Environnement actif' : 'Actuellement arrêté'}</p>
                </div>
                <span class="instance-card__status ${instance.status}">${instance.status}</span>
            </div>
            <div class="dashboard-instance-card__meta">
                <span><i class="bi bi-globe2"></i> App ${instance.config.VHOSTS || '-'}</span>
                <span><i class="bi bi-database"></i> DB :${instance.config.DB_PORT || '-'}</span>
            </div>
            <div class="dashboard-instance-card__actions">
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-select="${instance.name}">Sélectionner</button>
                <button class="btn btn-sm btn-success" type="button" data-dashboard-action="up" data-dashboard-instance="${instance.name}">Démarrer</button>
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-action="down" data-dashboard-instance="${instance.name}">Arrêter</button>
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-action="restart" data-dashboard-instance="${instance.name}">Redémarrer</button>
                <button class="btn btn-sm btn-outline-danger" type="button" data-dashboard-action="destroy" data-dashboard-instance="${instance.name}">Détruire</button>
            </div>
            <div class="dashboard-instance-card__footer">
                ${appLinks}
                <button class="btn btn-link p-0 dashboard-link-button" type="button" data-dashboard-view="settings" data-dashboard-instance="${instance.name}">Ouvrir les paramètres</button>
                <button class="btn btn-link p-0 dashboard-link-button" type="button" data-dashboard-view="shell" data-dashboard-instance="${instance.name}">Ouvrir la console</button>
            </div>
        `;

        instanceList.appendChild(card);
    });

    const selected = getSelectedInstance() || state.instances[0];
    state.selectedInstanceName = selected.name;
    fillForm(selected);
    renderDashboardInstances();
}

function renderSidebarInstances() {
    sidebarInstanceList.innerHTML = '';

    if (state.instances.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'empty-state';
        empty.textContent = 'Pas encore d\'instances.';
        sidebarInstanceList.appendChild(empty);
        return;
    }

    state.instances.forEach((instance) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = `sidebar-instance-button${instance.name === state.selectedInstanceName ? ' active' : ''}`;
        button.dataset.instanceName = instance.name;
        button.innerHTML = `
            <span class="sidebar-instance-button__name">${instance.name}</span>
            <span class="instance-card__status ${instance.status}">${instance.status}</span>
        `;

        button.addEventListener('click', () => {
            state.selectedInstanceName = instance.name;
            renderInstances();
            fillForm(instance);
            setMessage(`${instance.name} chargé.`);
        });

        sidebarInstanceList.appendChild(button);
    });
}

function renderDashboardInstances() {
    dashboardInstanceGrid.innerHTML = '';

    if (state.instances.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'empty-state';
        empty.textContent = 'Pas encore d\'instances. Créez-en une depuis la vue Instances.';
        dashboardInstanceGrid.appendChild(empty);
        return;
    }

    state.instances.forEach((instance) => {
        const appUrls = parseVhostUrls(instance);

        const card = document.createElement('article');
        card.className = `dashboard-instance-card${instance.name === state.selectedInstanceName ? ' active' : ''}`;

        const appLinks = appUrls.map((entry) =>
            `<a class="btn btn-link p-0 dashboard-link-button" href="${entry.url}" target="_blank" rel="noreferrer">Ouvrir ${entry.label}</a>`
        ).join('');

        card.innerHTML = `
            <div class="dashboard-instance-card__head">
                <div>
                    <h3 class="dashboard-instance-card__title">${instance.name}</h3>
                    <p class="dashboard-instance-card__subtitle">${instance.status === 'running' ? 'Environnement actif' : 'Actuellement arrêté'}</p>
                </div>
                <span class="instance-card__status ${instance.status}">${instance.status}</span>
            </div>
            <div class="dashboard-instance-card__meta">
                <span><i class="bi bi-globe2"></i> App ${instance.config.VHOSTS || '-'}</span>
                <span><i class="bi bi-database"></i> DB :${instance.config.DB_PORT || '-'}</span>
            </div>
            <div class="dashboard-instance-card__actions">
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-select="${instance.name}">Sélectionner</button>
                <button class="btn btn-sm btn-success" type="button" data-dashboard-action="up" data-dashboard-instance="${instance.name}">Démarrer</button>
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-action="down" data-dashboard-instance="${instance.name}">Arrêter</button>
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-action="restart" data-dashboard-instance="${instance.name}">Redémarrer</button>
                <button class="btn btn-sm btn-outline-danger" type="button" data-dashboard-action="destroy" data-dashboard-instance="${instance.name}">Détruire</button>
            </div>
            <div class="dashboard-instance-card__footer">
                ${appLinks}
                <button class="btn btn-link p-0 dashboard-link-button" type="button" data-dashboard-view="settings" data-dashboard-instance="${instance.name}">Ouvrir les paramètres</button>
                <button class="btn btn-link p-0 dashboard-link-button" type="button" data-dashboard-view="shell" data-dashboard-instance="${instance.name}">Ouvrir la console</button>
            </div>
        `;

        dashboardInstanceGrid.appendChild(card);
    });
}

async function refreshInstances(preserveSelection = true) {
    const previousSelection = preserveSelection ? state.selectedInstanceName : null;
    const payload = await apiRequest('/api/instances');
    state.instances = payload.instances;

    if (previousSelection && state.instances.some((instance) => instance.name === previousSelection)) {
        state.selectedInstanceName = previousSelection;
    } else {
        state.selectedInstanceName = state.instances[0]?.name || null;
    }

    renderInstances();
}

function collectFormData() {
    const config = {};

    fieldNames.forEach((fieldName) => {
        const element = form.elements.namedItem(fieldName);
        if (!element) {
            return;
        }

        if (element.type === 'checkbox') {
            config[fieldName] = element.checked ? 'true' : 'false';
            return;
        }

        config[fieldName] = element.value.trim();
    });

    return config;
}

createForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const formData = new FormData(createForm);
    const name = String(formData.get('name') || '').trim();
    const withDockerOverrides = formData.get('withDockerOverrides') === 'on';

    if (!name) {
        setMessage('Entrez d\'abord un nom d\'instance.', true);
        return;
    }

    try {
        setMessage(`Création de ${name}...`);
        const payload = await apiRequest('/api/instances', {
            method: 'POST',
            body: JSON.stringify({ name, withDockerOverrides }),
        });
        createForm.reset();
        // Reset checkbox to checked by default
        document.querySelector('#with-docker-overrides').checked = true;
        await refreshInstances(false);
        state.selectedInstanceName = payload.instance.name;
        renderInstances();
        setMessage(`${payload.instance.name} créé.`);
    } catch (error) {
        setMessage(error.message, true);
    }
});

form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const instance = getSelectedInstance();

    if (!instance) {
        setMessage('Sélectionnez une instance avant d\'enregistrer.', true);
        return;
    }

    try {
        setMessage(`Enregistrement de ${instance.name}...`);
        await apiRequest(`/api/instances/${instance.name}`, {
            method: 'PUT',
            body: JSON.stringify({ config: collectFormData() }),
        });
        await refreshInstances();
        setMessage(`${instance.name} enregistré. Redémarrez le stack si vous avez modifié les paramètres d'exécution.`);
    } catch (error) {
        setMessage(error.message, true);
    }
});

actionButtons.forEach((button) => {
    button.addEventListener('click', async () => {
        const instance = getSelectedInstance();
        const action = button.dataset.action;

        if (!instance) {
            setMessage('Sélectionnez d\'abord une instance.', true);
            return;
        }

        await runInstanceAction(instance.name, action);
    });
});

refreshButton.addEventListener('click', async () => {
    try {
        setMessage('Actualisation des instances...');
        await refreshInstances();
        setMessage('Instances actualisées.');
    } catch (error) {
        setMessage(error.message, true);
    }
});

async function handleDashboardCardClick(event) {
    const target = event.target.closest('button');
    if (!target) {
        return;
    }

    const selectedInstanceName = target.dataset.dashboardSelect || target.dataset.dashboardInstance;
    if (!selectedInstanceName) {
        return;
    }

    const instance = state.instances.find((entry) => entry.name === selectedInstanceName);
    if (!instance) {
        setMessage('Instance introuvable.', true);
        return;
    }

    if (target.dataset.dashboardSelect) {
        state.selectedInstanceName = selectedInstanceName;
        renderInstances();
        fillForm(instance);
        setMessage(`${selectedInstanceName} chargé.`);
        return;
    }

    if (target.dataset.dashboardView) {
        state.selectedInstanceName = selectedInstanceName;
        renderInstances();
        fillForm(instance);
        setActiveView(target.dataset.dashboardView);
        setMessage(`${selectedInstanceName} chargé.`);
        return;
    }

    if (target.dataset.dashboardAction) {
        await runInstanceAction(selectedInstanceName, target.dataset.dashboardAction);
    }
}

dashboardInstanceGrid.addEventListener('click', handleDashboardCardClick);
instanceList.addEventListener('click', handleDashboardCardClick);

sectionNavButtons.forEach((button) => {
    button.addEventListener('click', () => {
        setActiveView(button.dataset.view);
    });
});

settingsTabButtons.forEach((button) => {
    button.addEventListener('click', () => {
        setSettingsTab(button.dataset.settingsTab);
    });
});

consoleShortcutButtons.forEach((button) => {
    button.addEventListener('click', () => {
        consoleCommand.value = button.dataset.consoleCommand || '';
        consoleCommand.focus();
    });
});

consoleSurface.addEventListener('click', () => {
    if (!consoleCommand.disabled) {
        consoleCommand.focus();
    }
});

consoleClearButton.addEventListener('click', () => {
    const instance = getSelectedInstance();
    if (!instance) {
        setConsoleOutput('Sélectionnez une instance en cours d\'exécution pour ouvrir sa console d\'espace de travail.');
        return;
    }

    if (instance.status !== 'running') {
        setConsoleOutput(`L'instance ${instance.name} est arrêtée. Démarrez-la pour utiliser la console web.`);
        return;
    }

    setConsoleOutput(`Connecté à ${instance.name}. L'état est préservé entre les commandes.`);
});

consoleForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const instance = getSelectedInstance();

    if (!instance) {
        setMessage('Sélectionnez d\'abord une instance.', true);
        return;
    }

    const command = consoleCommand.value.trim();
    if (!command) {
        setMessage('Entrez d\'abord une commande.', true);
        return;
    }

    if (!state.consoleSessionId || state.consoleInstanceName !== instance.name) {
        setMessage('La session de console n\'est pas encore prête.', true);
        return;
    }

    try {
        consoleCommand.disabled = true;
        setConsoleStatus('session: occupée');
        appendConsoleOutput(`$ ${command}`);
        consoleCommand.value = '';
        setMessage(`Envoi de la commande à ${instance.name}...`);
        await apiRequest(`/api/instances/${instance.name}/console/input`, {
            method: 'POST',
            body: JSON.stringify({ sessionId: state.consoleSessionId, input: command }),
        });
        stopConsolePolling();
        state.consolePollTimer = window.setTimeout(pollConsoleOutput, 150);
        setMessage(`Commande envoyée à ${instance.name}.`);
    } catch (error) {
        setMessage(error.message, true);
        appendConsoleOutput(`[erreur]\n${error.message}`);
        setConsoleStatus('session: hors ligne');
    } finally {
        consoleCommand.disabled = false;
        if (state.activeView === 'shell' && !consoleCommand.disabled) {
            consoleCommand.focus();
        }
    }
});

logoutButton.addEventListener('click', async () => {
    try {
        await apiRequest('/api/auth/logout', {
            method: 'POST',
        });
        window.location.replace('/login');
    } catch (error) {
        setMessage(error.message, true);
    }
});

// ── Docker Overrides ──

const dockerOverridesStatus = document.querySelector('#docker-overrides-status');
const dockerOverridesMessage = document.querySelector('#docker-overrides-message');
const dockerOverridesActions = document.querySelector('#docker-overrides-actions');
const enableDockerOverridesButton = document.querySelector('#enable-docker-overrides');

async function checkDockerOverrides() {
    const instance = getSelectedInstance();
    if (!instance) {
        dockerOverridesMessage.textContent = 'Sélectionnez une instance pour voir le statut des surcharges Docker.';
        dockerOverridesActions.style.display = 'none';
        return;
    }

    try {
        const payload = await apiRequest(`/api/instances/${instance.name}/docker-overrides`);
        if (payload.enabled) {
            dockerOverridesStatus.innerHTML = `
                <div class="alert alert-success mb-0">
                    <i class="bi bi-check-circle me-2"></i>
                    Les surcharges Docker sont <strong>activées</strong> pour cette instance.
                    <div class="mt-2">
                        <small class="d-block">Fichiers: ${payload.files.join(', ')}</small>
                        <a href="#files" class="btn btn-sm btn-outline-success mt-2" onclick="setActiveView('files')">
                            <i class="bi bi-folder2-open me-1"></i>Voir les fichiers
                        </a>
                    </div>
                </div>
            `;
            dockerOverridesActions.style.display = 'none';
        } else {
            dockerOverridesMessage.textContent = 'Les surcharges Docker ne sont pas activées pour cette instance.';
            dockerOverridesStatus.innerHTML = `
                <div class="alert alert-warning mb-0">
                    <i class="bi bi-exclamation-triangle me-2"></i>
                    <span>Les surcharges Docker ne sont <strong>pas activées</strong> pour cette instance.</span>
                </div>
            `;
            dockerOverridesActions.style.display = 'block';
        }
    } catch {
        dockerOverridesMessage.textContent = 'Impossible de vérifier le statut des surcharges Docker.';
        dockerOverridesActions.style.display = 'none';
    }
}

enableDockerOverridesButton.addEventListener('click', async () => {
    const instance = getSelectedInstance();
    if (!instance) {
        setMessage('Sélectionnez d\'abord une instance.', true);
        return;
    }

   try {
        enableDockerOverridesButton.disabled = true;
        setMessage(`Activation des surcharges Docker pour ${instance.name}...`);
        await apiRequest(`/api/instances/${instance.name}/docker-overrides`, {
            method: 'POST',
        });
        setMessage(`Surcharges Docker activées pour ${instance.name}.`);
        await checkDockerOverrides();
    } catch (error) {
        setMessage(error.message, true);
        enableDockerOverridesButton.disabled = false;
    }
});

// Check docker overrides when selecting an instance
settingsTabButtons.forEach((button) => {
    button.addEventListener('click', () => {
        if (button.dataset.settingsTab === 'stack') {
            setTimeout(checkDockerOverrides, 100);
        }
    });
});

(async () => {
    try {
        setFormEnabled(false);
        setConsoleEnabled(false);
        setConsoleStatus('session: hors ligne');
        setSettingsTab(state.settingsTab);
        await loadDbserverInstances();
        await refreshInstances();
        setActiveView('dashboard');
        setMessage(state.instances.length ? 'Sélectionnez une instance pour déverrouiller l\'\u00e9dition.' : 'Créez votre première instance pour déverrouiller l\'\u00e9diteur.');
    } catch (error) {
        setMessage(error.message, true);
    }
})();

window.addEventListener('beforeunload', () => {
    stopConsolePolling();
});
