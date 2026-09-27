const authView = document.querySelector('#auth-view');
const bankView = document.querySelector('#bank-view');
const authForm = document.querySelector('#auth-form');
const authMessage = document.querySelector('#auth-message');
const actionDialog = document.querySelector('#action-dialog');
const actionForm = document.querySelector('#action-form');
let authMode = 'login';
let currentDashboard;
let toastTimer;

const money = (cents) => new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD', minimumFractionDigits: 2,
}).format(cents / 100);

const esc = (value) => String(value).replace(/[&<>"']/g, (character) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[character]));

async function api(path, values) {
  const options = { method: values ? 'POST' : 'GET', credentials: 'same-origin' };
  if (values) options.body = new URLSearchParams(values);
  const response = await fetch(path, options);
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'request_failed');
  return result;
}

function showAuth() {
  authView.classList.remove('hidden');
  bankView.classList.add('hidden');
  document.querySelector('#logout-button').classList.add('hidden');
}

function showBank() {
  authView.classList.add('hidden');
  bankView.classList.remove('hidden');
  document.querySelector('#logout-button').classList.remove('hidden');
}

function renderDashboard(data) {
  currentDashboard = data;
  showBank();
  document.querySelector('#customer-name').textContent = data.user.name.split(' ')[0];
  document.querySelector('#customer-number').textContent = data.user.customer_number;
  document.querySelector('#total-balance').textContent = money(data.total_balance_cents);
  document.querySelector('#account-count').textContent = data.accounts.length;

  document.querySelector('#account-list').innerHTML = data.accounts.map((account) => {
    const savings = account.type === 'mudarabah';
    const title = savings ? 'Mudarabah' : 'Current account';
    const detail = savings ? 'Profit-sharing · No guaranteed return' : 'Everyday spending · No overdraft';
    return `<div class="account-row">
      <div class="account-main"><span class="account-icon ${savings ? 'mudarabah' : ''}">${savings ? '◈' : '◌'}</span>
        <span><span class="account-name">${title}</span><br><span class="account-subtitle">${detail}</span></span>
      </div><span class="account-balance">${money(account.balance_cents)}</span>
    </div>`;
  }).join('');
  document.querySelector('#open-savings').classList.toggle('hidden',
    data.accounts.some((account) => account.type === 'mudarabah'));
  document.querySelector('#move-funds').classList.toggle('hidden', data.accounts.length < 2);

  const transactions = data.transactions;
  document.querySelector('#empty-activity').classList.toggle('hidden', transactions.length !== 0);
  document.querySelector('table').classList.toggle('hidden', transactions.length === 0);
  document.querySelector('#transaction-list').innerHTML = transactions.map((entry) => {
    const outgoing = ['withdrawal', 'transfer_sent', 'allocation_out'].includes(entry.type);
    const label = ({
      deposit: 'Sandbox deposit', withdrawal: 'Cash withdrawal',
      transfer_sent: 'Transfer sent', transfer_received: 'Transfer received',
      allocation_out: 'Moved between accounts', allocation_in: 'Moved between accounts',
    })[entry.type] || 'Account activity';
    const sign = outgoing ? '−' : '+';
    const date = new Date(entry.created_at).toLocaleDateString('en-US', {
      month: 'short', day: 'numeric', year: 'numeric',
    });
    const account = data.accounts.find((item) => item.id === entry.account_id);
    const accountName = account?.type === 'mudarabah' ? 'Mudarabah' : 'Current account';
    const note = entry.note ? ` · ${esc(entry.note)}` : '';
    return `<tr>
      <td><span class="transaction-type"><span class="transaction-mark ${outgoing ? 'outgoing' : ''}">${outgoing ? '↗' : '＋'}</span>${label}${note}</span></td>
      <td class="transaction-account">${accountName}</td><td>${date}</td>
      <td class="amount-cell ${outgoing ? 'negative' : ''}">${sign}${money(entry.amount_cents)}</td>
    </tr>`;
  }).join('');
}

function authError(message) {
  const errors = {
    email_already_registered: 'That email already has an account. Try signing in.',
    invalid_credentials: 'Customer number or password did not match.',
    invalid_email: 'Enter a valid email address.',
    invalid_name: 'Enter a name between 2 and 80 characters.',
    password_too_short: 'Use a password with at least 10 characters.',
  };
  return errors[message] || 'We could not complete that request. Please try again.';
}

document.querySelectorAll('[data-auth-mode]').forEach((button) => {
  button.addEventListener('click', () => {
    authMode = button.dataset.authMode;
    const registering = authMode === 'register';
    document.querySelectorAll('[data-auth-mode]').forEach((tab) => {
      const active = tab === button;
      tab.classList.toggle('active', active);
      tab.setAttribute('aria-selected', String(active));
    });
    document.querySelector('#name-field').classList.toggle('hidden', !registering);
    document.querySelector('#name-field input').required = registering;
    const identityInput = document.querySelector('#identity-input');
    identityInput.name = registering ? 'email' : 'customer_number';
    identityInput.type = registering ? 'email' : 'text';
    identityInput.inputMode = registering ? 'email' : 'numeric';
    identityInput.autocomplete = registering ? 'email' : 'username';
    identityInput.pattern = registering ? '' : '[0-9]{10}';
    identityInput.maxLength = registering ? 254 : 10;
    identityInput.placeholder = registering ? 'you@example.com' : '10-digit customer number';
    document.querySelector('#identity-label').textContent = registering
      ? 'Email address' : 'Customer number';
    document.querySelector('#auth-title').textContent = registering ? 'Start with intention' : 'Welcome back';
    document.querySelector('#auth-description').textContent = registering
      ? 'Create a private account in a few moments.' : 'Sign in to continue to your account.';
    document.querySelector('#auth-submit').innerHTML = registering
      ? 'Create my account <span aria-hidden="true">→</span>'
      : 'Sign in <span aria-hidden="true">→</span>';
    authForm.elements.password.autocomplete = registering ? 'new-password' : 'current-password';
    authMessage.textContent = '';
  });
});

authForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const submit = document.querySelector('#auth-submit');
  submit.disabled = true;
  authMessage.textContent = '';
  const values = Object.fromEntries(new FormData(authForm));
  try {
    const result = await api(`/api/${authMode}`, values);
    authForm.reset();
    renderDashboard(result);
  } catch (error) {
    authMessage.textContent = authError(error.message);
  } finally {
    submit.disabled = false;
  }
});

document.querySelector('#toggle-password').addEventListener('click', (event) => {
  const button = event.currentTarget;
  const input = document.querySelector('#password-input');
  const showing = input.type === 'password';
  input.type = showing ? 'text' : 'password';
  button.classList.toggle('password-visible', showing);
  button.setAttribute('aria-pressed', String(showing));
  button.setAttribute('aria-label', showing ? 'Hide password' : 'Show password');
  button.title = showing ? 'Hide password' : 'Show password';
});

function actionTemplate(action) {
  if (action === 'move') {
    const options = currentDashboard.accounts.map((account) => {
      const label = account.type === 'mudarabah' ? 'Mudarabah' : 'Current account';
      return `<option value="${esc(account.id)}">${label} · ${money(account.balance_cents)}</option>`;
    });
    return {
      title: 'Move between accounts', endpoint: '/api/accounts/move',
      fields: `<label>From<select name="from" required>${options.join('')}</select></label>
        <label>To<select name="to" required>${options.slice().reverse().join('')}</select></label>
        <label>Amount in USD<input name="amount" type="number" min="0.01" step="0.01" required placeholder="0.00"></label>
        <p class="tiny-note">This moves your balance between your own accounts; it does not create a return.</p>`,
      submit: 'Move funds',
    };
  }
  if (action === 'transfer') {
    return {
      title: 'Send money', endpoint: '/api/transfer',
      fields: `<label>Recipient email<input name="email" type="email" required placeholder="recipient@example.com"></label>
        <label>Amount in USD<input name="amount" type="number" min="0.01" step="0.01" required placeholder="0.00"></label>
        <label>Note <span class="tiny-note">Optional, up to 120 characters</span><input name="note" maxlength="120" placeholder="What is this for?"></label>`,
      submit: 'Review sandbox transfer',
    };
  }
  const deposit = action === 'deposit';
  return {
    title: deposit ? 'Add sandbox funds' : 'Withdraw funds',
    endpoint: deposit ? '/api/deposit' : '/api/withdraw',
    fields: `<p class="planning-description">${deposit
      ? 'This simulates an incoming transfer. It does not connect to a real bank or move real funds.'
      : 'Withdrawals are limited to your available sandbox balance.'}</p>
      <label>Amount in USD<input name="amount" type="number" min="0.01" step="0.01" required placeholder="0.00"></label>`,
    submit: deposit ? 'Add demo funds' : 'Withdraw',
  };
}

document.querySelectorAll('[data-action]').forEach((button) => {
  button.addEventListener('click', () => {
    const template = actionTemplate(button.dataset.action);
    document.querySelector('#dialog-title').textContent = template.title;
    actionForm.action = template.endpoint;
    actionForm.innerHTML = `${template.fields}<button class="button button-primary button-wide" type="submit">${template.submit}</button>`;
    document.querySelector('#action-message').textContent = '';
    actionDialog.showModal();
  });
});

actionForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const submit = actionForm.querySelector('[type="submit"]');
  submit.disabled = true;
  try {
    const data = await api(actionForm.action, Object.fromEntries(new FormData(actionForm)));
    renderDashboard(data);
    actionDialog.close();
    showToast('Your sandbox ledger has been updated.');
  } catch (error) {
    document.querySelector('#action-message').textContent = authError(error.message);
  } finally {
    submit.disabled = false;
  }
});

document.querySelector('#dialog-close').addEventListener('click', () => actionDialog.close());
actionDialog.addEventListener('click', (event) => {
  if (event.target === actionDialog) actionDialog.close();
});

document.querySelector('#open-savings').addEventListener('click', async () => {
  try {
    const data = await api('/api/accounts/savings', {});
    renderDashboard(data);
    showToast('Your mudarabah account is ready.');
  } catch (error) {
    showToast(error.message === 'savings_account_exists'
      ? 'You already have a mudarabah account.' : authError(error.message));
  }
});

document.querySelector('#move-funds').addEventListener('click', () => {
  const template = actionTemplate('move');
  document.querySelector('#dialog-title').textContent = template.title;
  actionForm.action = template.endpoint;
  actionForm.innerHTML = `${template.fields}<button class="button button-primary button-wide" type="submit">${template.submit}</button>`;
  document.querySelector('#action-message').textContent = '';
  actionDialog.showModal();
});

document.querySelector('#zakat-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const result = document.querySelector('#zakat-result');
  try {
    const data = await api('/api/zakat', Object.fromEntries(new FormData(event.currentTarget)));
    result.textContent = data.estimated_zakat_cents
      ? `Illustrative amount: ${money(data.estimated_zakat_cents)}`
      : 'Your listed balances are below the nisab value entered.';
  } catch (error) {
    result.textContent = authError(error.message);
  }
});

function calculateMurabaha() {
  const values = new FormData(document.querySelector('#murabaha-form'));
  const cost = Number(values.get('cost'));
  const markup = Number(values.get('markup'));
  const months = Number(values.get('months'));
  if (!(cost > 0 && markup >= 0 && markup <= 30 && months >= 1)) return;
  const salePrice = Math.round(cost * 100 * (1 + markup / 100));
  document.querySelector('#murabaha-monthly').textContent = money(Math.round(salePrice / months));
  document.querySelector('#murabaha-detail').textContent =
    `Illustrative sale price ${money(salePrice)} · ${markup}% disclosed markup · ${months} fixed instalments`;
}

document.querySelector('#murabaha-form').addEventListener('input', calculateMurabaha);
calculateMurabaha();

document.querySelector('#logout-button').addEventListener('click', async () => {
  await api('/api/logout', {});
  showAuth();
  showToast('You have signed out.');
});

document.querySelector('#copy-customer-number').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(currentDashboard.user.customer_number);
    showToast('Customer number copied.');
  } catch (_error) {
    showToast('Could not copy customer number.');
  }
});

document.querySelectorAll('.nav-link').forEach((link) => {
  link.addEventListener('click', () => {
    document.querySelectorAll('.nav-link').forEach((item) => item.classList.remove('active'));
    link.classList.add('active');
  });
});

function showToast(message) {
  const toast = document.querySelector('#toast');
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 3200);
}

api('/api/me').then(renderDashboard).catch(showAuth);