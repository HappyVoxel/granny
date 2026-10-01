const portInput = document.getElementById('port');
const tokenInput = document.getElementById('token');
const status = document.getElementById('status');

chrome.storage.local.get({ decidePort: 47899, token: '' }).then((settings) => {
  portInput.value = settings.decidePort;
  tokenInput.value = settings.token;
});

document.getElementById('save').addEventListener('click', async () => {
  await chrome.storage.local.set({
    decidePort: Number(portInput.value) || 47899,
    token: tokenInput.value.trim(),
  });
  status.textContent = 'Saved.';
  setTimeout(() => (status.textContent = ''), 1500);
});
