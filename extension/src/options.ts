const portInput = document.getElementById('port') as HTMLInputElement;
const tokenInput = document.getElementById('token') as HTMLInputElement;
const statusLine = document.getElementById('status') as HTMLElement;

chrome.storage.local
  .get<GrannySettings>({ decidePort: 47899, token: '' })
  .then((settings) => {
    portInput.value = String(settings.decidePort);
    tokenInput.value = settings.token;
  });

(document.getElementById('save') as HTMLButtonElement).addEventListener('click', async () => {
  await chrome.storage.local.set({
    decidePort: Number(portInput.value) || 47899,
    token: tokenInput.value.trim(),
  });
  statusLine.textContent = 'Saved.';
  setTimeout(() => (statusLine.textContent = ''), 1500);
});
