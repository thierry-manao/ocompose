const state = {
    instances: [],
    selectedInstanceName: null,
    activeView: 'dashboard',
    consoleSessionId: null,
    consoleCursor: 0,
    consoleInstanceName: null,
    consolePollTimer: null,
};

const form = document.querySelector('#config-form');
const createForm = document.querySelector('#create-form');
const instanceList = document.querySelector('#instance-list');
const instanceTitle = document.querySelector('#instance-title');
const instanceSubtitle = document.querySelector('#instance-subtitle');
const statusChip = document.querySelector('#status-chip');
const messageBar = document.querySelector('#message-bar');
const appLink = document.querySelector('#app-link');
const pmaLink = document.querySelector('#pma-link');
const sshTarget = document.querySelector('#ssh-target');
const consoleLink = document.querySelector('#console-link');
const heroAppPort = document.querySelector('#hero-app-port');
const heroMysqlPort = document.querySelector('#hero-mysql-port');
const heroSshPort = document.querySelector('#hero-ssh-port');
const refreshButton = document.querySelector('#refresh-button');
const logoutButton = document.querySelector('#logout-button');
const actionButtons = Array.from(document.querySelectorAll('[data-action]'));
const sectionNavButtons = Array.from(document.querySelectorAll('[data-view]'));
const viewPanels = Array.from(document.querySelectorAll('[data-view-panel]'));
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

const fieldNames = [
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
];

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
        throw new Error(payload.error || 'Request failed.');
    }

    return payload;
}

function getSelectedInstance() {
    return state.instances.find((instance) => instance.name === state.selectedInstanceName) || null;
}

async function runInstanceAction(instanceName, action) {
    const instance = state.instances.find((entry) => entry.name === instanceName);
    if (!instance) {
        setMessage('Instance not found.', true);
        return;
    }

    if (action === 'destroy' && !window.confirm(`Destroy ${instance.name} and remove its data?`)) {
        return;
    }

    try {
        setMessage(`${action} ${instance.name}...`);
        await apiRequest(`/api/instances/${instance.name}/actions/${action}`, {
            method: 'POST',
        });

        if (action === 'destroy') {
            await refreshInstances(false);
            setMessage(`Destroyed ${instance.name}.`);
            return;
        }

        await refreshInstances();
        setMessage(`${action} completed for ${instance.name}.`);
    } catch (error) {
        setMessage(error.message, true);
    }
}

function updateEndpoints(instance) {
    const appUrl = instance?.urls?.app || null;
    const pmaUrl = instance?.urls?.phpmyadmin || null;
    const sshUrl = instance?.urls?.ssh || null;

    appLink.textContent = appUrl || 'Not available';
    appLink.href = appUrl || '#';
    appLink.style.pointerEvents = appUrl ? 'auto' : 'none';

    pmaLink.textContent = pmaUrl || 'Not available';
    pmaLink.href = pmaUrl || '#';
    pmaLink.style.pointerEvents = pmaUrl ? 'auto' : 'none';

    sshTarget.textContent = sshUrl || 'Not available';
    consoleLink.classList.toggle('disabled', !instance);
    heroAppPort.textContent = instance?.config?.APP_PORT || '-';
    heroMysqlPort.textContent = instance?.config?.MYSQL_PORT || '-';
    heroSshPort.textContent = instance?.config?.WORKSPACE_SSH_PORT || '-';
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
        setConsoleStatus(payload.closed ? 'session: closed' : payload.busy ? 'session: busy' : 'session: ready');

        if (!payload.closed && state.consoleSessionId === payload.sessionId) {
            state.consolePollTimer = window.setTimeout(pollConsoleOutput, 800);
            return;
        }

        state.consoleSessionId = null;
    } catch (error) {
        setConsoleStatus('session: offline');
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
    setConsoleStatus('session: ready');
    consoleCwd.textContent = `cwd: ${payload.cwd || 'unavailable'}`;
    setConsoleOutput(`Connected to ${instance.name}. State is preserved between commands.`);
    stopConsolePolling();
    state.consolePollTimer = window.setTimeout(pollConsoleOutput, 800);
}

function updateConsoleState(instance) {
    updateConsolePrompt(instance);

    if (!instance) {
        stopConsolePolling();
        setConsoleEnabled(false);
        consoleSubtitle.textContent = 'Commands run inside the selected workspace container from its project root.';
        consoleCwd.textContent = 'cwd: unavailable';
        setConsoleStatus('session: offline');
        setConsoleOutput('Select a running instance to open its workspace console.');
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
        consoleSubtitle.textContent = 'Start the instance first. Commands only run against a live workspace container.';
        setConsoleStatus('session: offline');
        setConsoleOutput(`Instance ${instance.name} is stopped. Start it to use the web console.`);
        return;
    }

    setConsoleEnabled(true);
    consoleSubtitle.textContent = `Commands run inside ${instance.name}_workspace from ${cwd}.`;
    setConsoleStatus(state.consoleSessionId && state.consoleInstanceName === instance.name ? 'session: ready' : 'session: connecting');

    if (!consoleOutput.dataset.instanceName || consoleOutput.dataset.instanceName !== instance.name) {
        setConsoleOutput(`Connecting to ${instance.name}...`);
    }

    consoleOutput.dataset.instanceName = instance.name;
    ensureConsoleSession(instance).catch((error) => {
        setConsoleStatus('session: offline');
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
        instanceTitle.textContent = 'Select an instance';
        instanceSubtitle.textContent = 'Create or select an instance to unlock configuration. Until then, the editor stays intentionally locked.';
        statusChip.textContent = 'idle';
        statusChip.className = 'status-chip idle';
        updateConsoleState(null);
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
    instanceSubtitle.textContent = 'These fields edit the same `.env` file used by the CLI and Docker Compose.';
    statusChip.textContent = instance.status;
    statusChip.className = `status-chip ${instance.status}`;
    updateEndpoints(instance);
    updateConsoleState(instance);
}

function renderInstances() {
    instanceList.innerHTML = '';
    renderSidebarInstances();

    if (state.instances.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'empty-state';
        empty.textContent = 'No instances yet. Create one to begin.';
        instanceList.appendChild(empty);
        fillForm(null);
        return;
    }

    state.instances.forEach((instance) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = `instance-card${instance.name === state.selectedInstanceName ? ' active' : ''}`;
        button.innerHTML = `
            <div class="instance-card__head">
                <strong class="instance-card__name">${instance.name}</strong>
                <span class="instance-card__status ${instance.status}">${instance.status}</span>
            </div>
            <div class="instance-card__meta">
                <span><i class="bi bi-globe2"></i> ${instance.config.APP_PORT || '-'}</span>
                <span><i class="bi bi-terminal"></i> ${instance.config.WORKSPACE_SSH_PORT || '-'}</span>
            </div>
        `;

        button.addEventListener('click', () => {
            state.selectedInstanceName = instance.name;
            renderInstances();
            fillForm(instance);
            setMessage(`Loaded ${instance.name}.`);
        });

        instanceList.appendChild(button);
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
        empty.textContent = 'No instances yet.';
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
            setMessage(`Loaded ${instance.name}.`);
        });

        sidebarInstanceList.appendChild(button);
    });
}

function renderDashboardInstances() {
    dashboardInstanceGrid.innerHTML = '';

    if (state.instances.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'empty-state';
        empty.textContent = 'No instances yet. Create one from the Instances view.';
        dashboardInstanceGrid.appendChild(empty);
        return;
    }

    state.instances.forEach((instance) => {
        const card = document.createElement('article');
        card.className = `dashboard-instance-card${instance.name === state.selectedInstanceName ? ' active' : ''}`;
        card.innerHTML = `
            <div class="dashboard-instance-card__head">
                <div>
                    <h3 class="dashboard-instance-card__title">${instance.name}</h3>
                    <p class="dashboard-instance-card__subtitle">${instance.status === 'running' ? 'Live environment' : 'Currently stopped'}</p>
                </div>
                <span class="instance-card__status ${instance.status}">${instance.status}</span>
            </div>
            <div class="dashboard-instance-card__meta">
                <span><i class="bi bi-globe2"></i> App ${instance.config.APP_PORT || '-'}</span>
                <span><i class="bi bi-database"></i> MySQL ${instance.config.MYSQL_PORT || '-'}</span>
                <span><i class="bi bi-terminal"></i> SSH ${instance.config.WORKSPACE_SSH_PORT || '-'}</span>
            </div>
            <div class="dashboard-instance-card__actions">
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-select="${instance.name}">Select</button>
                <button class="btn btn-sm btn-success" type="button" data-dashboard-action="up" data-dashboard-instance="${instance.name}">Start</button>
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-action="down" data-dashboard-instance="${instance.name}">Stop</button>
                <button class="btn btn-sm btn-outline-dark" type="button" data-dashboard-action="restart" data-dashboard-instance="${instance.name}">Restart</button>
                <button class="btn btn-sm btn-outline-danger" type="button" data-dashboard-action="destroy" data-dashboard-instance="${instance.name}">Destroy</button>
            </div>
            <div class="dashboard-instance-card__footer">
                <button class="btn btn-link p-0 dashboard-link-button" type="button" data-dashboard-view="settings" data-dashboard-instance="${instance.name}">Open settings</button>
                <button class="btn btn-link p-0 dashboard-link-button" type="button" data-dashboard-view="shell" data-dashboard-instance="${instance.name}">Open shell</button>
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

    if (!name) {
        setMessage('Enter an instance name first.', true);
        return;
    }

    try {
        setMessage(`Creating ${name}...`);
        const payload = await apiRequest('/api/instances', {
            method: 'POST',
            body: JSON.stringify({ name }),
        });
        createForm.reset();
        await refreshInstances(false);
        state.selectedInstanceName = payload.instance.name;
        renderInstances();
        setMessage(`Created ${payload.instance.name}.`);
    } catch (error) {
        setMessage(error.message, true);
    }
});

form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const instance = getSelectedInstance();

    if (!instance) {
        setMessage('Select an instance before saving.', true);
        return;
    }

    try {
        setMessage(`Saving ${instance.name}...`);
        await apiRequest(`/api/instances/${instance.name}`, {
            method: 'PUT',
            body: JSON.stringify({ config: collectFormData() }),
        });
        await refreshInstances();
        setMessage(`Saved ${instance.name}. Restart the stack if you changed runtime settings.`);
    } catch (error) {
        setMessage(error.message, true);
    }
});

actionButtons.forEach((button) => {
    button.addEventListener('click', async () => {
        const instance = getSelectedInstance();
        const action = button.dataset.action;

        if (!instance) {
            setMessage('Select an instance first.', true);
            return;
        }

        await runInstanceAction(instance.name, action);
    });
});

refreshButton.addEventListener('click', async () => {
    try {
        setMessage('Refreshing instances...');
        await refreshInstances();
        setMessage('Instances refreshed.');
    } catch (error) {
        setMessage(error.message, true);
    }
});

dashboardInstanceGrid.addEventListener('click', async (event) => {
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
        setMessage('Instance not found.', true);
        return;
    }

    if (target.dataset.dashboardSelect) {
        state.selectedInstanceName = selectedInstanceName;
        renderInstances();
        fillForm(instance);
        setMessage(`Loaded ${selectedInstanceName}.`);
        return;
    }

    if (target.dataset.dashboardView) {
        state.selectedInstanceName = selectedInstanceName;
        renderInstances();
        fillForm(instance);
        setActiveView(target.dataset.dashboardView);
        setMessage(`Loaded ${selectedInstanceName}.`);
        return;
    }

    if (target.dataset.dashboardAction) {
        await runInstanceAction(selectedInstanceName, target.dataset.dashboardAction);
    }
});

sectionNavButtons.forEach((button) => {
    button.addEventListener('click', () => {
        setActiveView(button.dataset.view);
    });
});

consoleLink.addEventListener('click', () => {
    setActiveView('shell');
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
        setConsoleOutput('Select a running instance to open its workspace console.');
        return;
    }

    if (instance.status !== 'running') {
        setConsoleOutput(`Instance ${instance.name} is stopped. Start it to use the web console.`);
        return;
    }

    setConsoleOutput(`Connected to ${instance.name}. State is preserved between commands.`);
});

consoleForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const instance = getSelectedInstance();

    if (!instance) {
        setMessage('Select an instance first.', true);
        return;
    }

    const command = consoleCommand.value.trim();
    if (!command) {
        setMessage('Enter a command first.', true);
        return;
    }

    if (!state.consoleSessionId || state.consoleInstanceName !== instance.name) {
        setMessage('Console session is not ready yet.', true);
        return;
    }

    try {
        consoleCommand.disabled = true;
        setConsoleStatus('session: busy');
        appendConsoleOutput(`$ ${command}`);
        consoleCommand.value = '';
        setMessage(`Sending command to ${instance.name}...`);
        await apiRequest(`/api/instances/${instance.name}/console/input`, {
            method: 'POST',
            body: JSON.stringify({ sessionId: state.consoleSessionId, input: command }),
        });
        stopConsolePolling();
        state.consolePollTimer = window.setTimeout(pollConsoleOutput, 150);
        setMessage(`Command sent to ${instance.name}.`);
    } catch (error) {
        setMessage(error.message, true);
        appendConsoleOutput(`[error]\n${error.message}`);
        setConsoleStatus('session: offline');
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

(async () => {
    try {
        setFormEnabled(false);
        setConsoleEnabled(false);
        setConsoleStatus('session: offline');
        await refreshInstances();
        setActiveView('dashboard');
        setMessage(state.instances.length ? 'Select an instance to unlock editing.' : 'Create your first instance to unlock the editor.');
    } catch (error) {
        setMessage(error.message, true);
    }
})();

window.addEventListener('beforeunload', () => {
    stopConsolePolling();
});
