const state = {
    instances: [],
    selectedInstanceName: null,
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
const refreshButton = document.querySelector('#refresh-button');
const actionButtons = Array.from(document.querySelectorAll('[data-action]'));

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

async function apiRequest(path, options = {}) {
    const response = await fetch(path, {
        headers: {
            'Content-Type': 'application/json',
            ...(options.headers || {}),
        },
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

function updateLinks(instance) {
    const appUrl = instance?.urls?.app;
    const pmaUrl = instance?.urls?.phpmyadmin;
    const sshUrl = instance?.urls?.ssh;

    appLink.textContent = appUrl || 'Not available';
    appLink.href = appUrl || '#';
    appLink.style.pointerEvents = appUrl ? 'auto' : 'none';

    pmaLink.textContent = pmaUrl || 'Not available';
    pmaLink.href = pmaUrl || '#';
    pmaLink.style.pointerEvents = pmaUrl ? 'auto' : 'none';

    sshTarget.textContent = sshUrl || 'Not available';
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
        updateLinks(null);
        instanceTitle.textContent = 'Select an instance';
        instanceSubtitle.textContent = 'The form edits the same .env file used by the CLI and Docker Compose.';
        statusChip.textContent = 'idle';
        statusChip.className = 'status-chip idle';
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
    instanceSubtitle.textContent = 'Save changes to rewrite the instance .env file. Start or restart afterward to apply container changes.';
    statusChip.textContent = instance.status;
    statusChip.className = `status-chip ${instance.status}`;
    updateLinks(instance);
}

function renderInstances() {
    instanceList.innerHTML = '';

    if (state.instances.length === 0) {
        const empty = document.createElement('p');
        empty.className = 'field-hint';
        empty.textContent = 'No instances yet. Create one from the panel above.';
        instanceList.appendChild(empty);
        fillForm(null);
        return;
    }

    state.instances.forEach((instance) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = `instance-card${instance.name === state.selectedInstanceName ? ' active' : ''}`;
        button.innerHTML = `
            <strong>${instance.name}</strong>
            <div class="instance-meta">
                <span>${instance.status}</span>
                <span>app ${instance.config.APP_PORT || '-'}</span>
                <span>ssh ${instance.config.WORKSPACE_SSH_PORT || '-'}</span>
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
        setMessage(`Created ${payload.instance.name}. Adjust settings, then start it.`);
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
        setMessage(`Saved ${instance.name}. Restart the stack if container settings changed.`);
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
    });
});

refreshButton.addEventListener('click', async () => {
    try {
        setMessage('Refreshing instances...');
        await refreshInstances();
        setMessage('Instance list refreshed.');
    } catch (error) {
        setMessage(error.message, true);
    }
});

(async () => {
    try {
        setFormEnabled(false);
        await refreshInstances();
        setMessage(state.instances.length ? 'Select an instance to edit it.' : 'Create your first instance to begin.');
    } catch (error) {
        setMessage(error.message, true);
    }
})();