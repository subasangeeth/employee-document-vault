/**
 * Employee Document Vault Frontend Application
 * Interacts with Amazon Cognito, API Gateway, and S3 Pre-signed URLs.
 */

// Application State
let currentUser = null;
let allDocuments = [];
let currentCategory = 'all';

// Initialize on DOM load
document.addEventListener('DOMContentLoaded', () => {
  initAuth();
  setupEventListeners();
});

function initAuth() {
  const token = sessionStorage.getItem('vault_id_token');
  const userStr = sessionStorage.getItem('vault_user');
  
  if (token && userStr) {
    try {
      currentUser = JSON.parse(userStr);
      // Check expiration
      const exp = currentUser.exp * 1000;
      if (Date.now() < exp) {
        renderAuthenticatedUI();
        loadDocuments();
        return;
      }
    } catch (e) {
      console.warn('Invalid cached session', e);
    }
  }
  showLoginModal();
}

function setupEventListeners() {
  const loginForm = document.getElementById('loginForm');
  if (loginForm) {
    loginForm.addEventListener('submit', handleLogin);
  }

  const uploadForm = document.getElementById('uploadForm');
  if (uploadForm) {
    uploadForm.addEventListener('submit', handleUpload);
  }
}

// -------------------------------------------------------------
// Authentication with Cognito
// -------------------------------------------------------------
async function handleLogin(e) {
  e.preventDefault();
  const username = document.getElementById('loginUsername').value.trim();
  const password = document.getElementById('loginPassword').value;
  const loginBtn = document.getElementById('loginBtn');
  const errorEl = document.getElementById('loginError');
  const errorTextEl = document.getElementById('loginErrorText');

  errorEl.classList.add('hidden');
  loginBtn.disabled = true;
  loginBtn.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> Signing In...`;

  try {
    const region = window.APP_CONFIG.AWS_REGION || 'us-east-2';
    const clientId = window.APP_CONFIG.COGNITO_CLIENT_ID;

    if (!clientId) {
      throw new Error('Cognito Client ID is not configured. Run deployment script first.');
    }

    const response = await fetch(`https://cognito-idp.${region}.amazonaws.com/`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth'
      },
      body: JSON.stringify({
        AuthFlow: 'USER_PASSWORD_AUTH',
        ClientId: clientId,
        AuthParameters: {
          USERNAME: username,
          PASSWORD: password
        }
      })
    });

    const data = await response.json();

    if (!response.ok) {
      throw new Error(data.message || data.__type || 'Authentication failed');
    }

    const authResult = data.AuthenticationResult;
    const idToken = authResult.IdToken;
    const accessToken = authResult.AccessToken;

    // Decode ID Token payload
    const payload = parseJwt(idToken);
    
    // Determine user role and employee_id
    const groups = payload['cognito:groups'] || [];
    let role = 'Employee';
    if (groups.includes('HR_Admin')) role = 'HR_Admin';
    else if (groups.includes('Manager')) role = 'Manager';
    else if (groups.includes('Employee')) role = 'Employee';
    else if (payload['custom:role']) role = payload['custom:role'];

    const employee_id = payload['custom:employee_id'] || payload['cognito:username'] || username;

    currentUser = {
      username: payload['cognito:username'] || username,
      employee_id: employee_id,
      role: role,
      groups: groups,
      idToken: idToken,
      accessToken: accessToken,
      exp: payload.exp
    };

    sessionStorage.setItem('vault_id_token', idToken);
    sessionStorage.setItem('vault_access_token', accessToken);
    sessionStorage.setItem('vault_user', JSON.stringify(currentUser));

    hideLoginModal();
    renderAuthenticatedUI();
    loadDocuments();

  } catch (err) {
    console.error('Login error:', err);
    errorTextEl.innerText = err.message || 'Authentication failed. Verify credentials.';
    errorEl.classList.remove('hidden');
  } finally {
    loginBtn.disabled = false;
    loginBtn.innerHTML = `<i class="fa-solid fa-arrow-right-to-bracket"></i> Sign In`;
  }
}

function quickLogin(username) {
  document.getElementById('loginUsername').value = username;
  document.getElementById('loginPassword').value = 'TempPass123!';
  document.getElementById('loginBtn').click();
}

function logout() {
  sessionStorage.removeItem('vault_id_token');
  sessionStorage.removeItem('vault_access_token');
  sessionStorage.removeItem('vault_user');
  currentUser = null;
  allDocuments = [];
  showLoginModal();
}

function parseJwt(token) {
  try {
    const base64Url = token.split('.')[1];
    const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
    const jsonPayload = decodeURIComponent(atob(base64).split('').map(function(c) {
        return '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2);
    }).join(''));
    return JSON.parse(jsonPayload);
  } catch (e) {
    return {};
  }
}

function showLoginModal() {
  document.getElementById('loginModal').classList.remove('hidden');
}

function hideLoginModal() {
  document.getElementById('loginModal').classList.add('hidden');
}

// -------------------------------------------------------------
// UI Rendering
// -------------------------------------------------------------
function renderAuthenticatedUI() {
  const controls = document.getElementById('authHeaderControls');
  
  let roleBadgeClass = 'bg-sky-950 text-sky-400 border-sky-800';
  let roleIcon = 'fa-user';
  if (currentUser.role === 'HR_Admin') {
    roleBadgeClass = 'bg-emerald-950 text-emerald-400 border-emerald-800';
    roleIcon = 'fa-user-shield';
  } else if (currentUser.role === 'Manager') {
    roleBadgeClass = 'bg-amber-950 text-amber-400 border-amber-800';
    roleIcon = 'fa-users-gear';
  }

  controls.innerHTML = `
    <div class="flex items-center space-x-3 bg-slate-900/80 border border-slate-700/80 px-3.5 py-1.5 rounded-xl">
      <div class="w-8 h-8 rounded-full bg-slate-700 flex items-center justify-center text-slate-200 text-xs font-bold">
        ${currentUser.employee_id.substring(0, 3)}
      </div>
      <div>
        <div class="text-xs font-bold text-white flex items-center gap-1.5">
          ${currentUser.employee_id}
          <span class="text-[10px] font-semibold px-2 py-0.5 rounded-full border ${roleBadgeClass} flex items-center gap-1">
            <i class="fa-solid ${roleIcon}"></i> ${currentUser.role}
          </span>
        </div>
        <div class="text-[10px] text-slate-400">${currentUser.username}</div>
      </div>
    </div>
    <button onclick="logout()" title="Sign Out"
      class="p-2 bg-slate-700/50 hover:bg-slate-700 border border-slate-600 rounded-lg text-slate-300 hover:text-white transition text-xs flex items-center gap-1.5">
      <i class="fa-solid fa-right-from-bracket"></i>
    </button>
  `;

  // Pre-fill target employee in upload modal
  const uploadEmpInput = document.getElementById('uploadEmployeeId');
  if (uploadEmpInput) {
    uploadEmpInput.value = currentUser.employee_id;
    if (currentUser.role === 'Employee') {
      uploadEmpInput.readOnly = true;
      uploadEmpInput.classList.add('opacity-75', 'cursor-not-allowed');
    } else {
      uploadEmpInput.readOnly = false;
      uploadEmpInput.classList.remove('opacity-75', 'cursor-not-allowed');
    }
  }

  // Show Employee Filter Dropdown for Manager and HR_Admin
  const filterContainer = document.getElementById('targetEmployeeFilterContainer');
  const employeeFilter = document.getElementById('employeeFilter');
  if (currentUser.role === 'Manager' || currentUser.role === 'HR_Admin') {
    filterContainer.classList.remove('hidden');
    employeeFilter.innerHTML = `<option value="">All Authorized Employees</option>`;
    if (currentUser.role === 'Manager') {
      employeeFilter.innerHTML += `
        <option value="${currentUser.employee_id}">Self (${currentUser.employee_id})</option>
        <option value="EMP001">EMP001 (Direct Report)</option>
        <option value="EMP002">EMP002 (Direct Report)</option>
        <option value="EMP003">EMP003 (Direct Report)</option>
      `;
    } else {
      employeeFilter.innerHTML += `
        <option value="EMP001">EMP001</option>
        <option value="EMP002">EMP002</option>
        <option value="EMP003">EMP003</option>
        <option value="MGR001">MGR001</option>
        <option value="HR001">HR001</option>
      `;
    }
  } else {
    filterContainer.classList.add('hidden');
  }
}

function showAlert(message, type = 'success') {
  const banner = document.getElementById('alertBanner');
  const bannerText = document.getElementById('alertBannerText');
  banner.className = 'p-4 rounded-xl border flex items-center justify-between text-sm transition';
  
  if (type === 'success') {
    banner.classList.add('bg-emerald-950/70', 'border-emerald-800', 'text-emerald-200');
    bannerText.innerHTML = `<i class="fa-solid fa-circle-check text-emerald-400 text-base"></i> <span>${message}</span>`;
  } else {
    banner.classList.add('bg-rose-950/70', 'border-rose-800', 'text-rose-200');
    bannerText.innerHTML = `<i class="fa-solid fa-circle-xmark text-rose-400 text-base"></i> <span>${message}</span>`;
  }
  banner.classList.remove('hidden');
  setTimeout(() => hideAlert(), 6000);
}

function hideAlert() {
  document.getElementById('alertBanner').classList.add('hidden');
}

// -------------------------------------------------------------
// Document Operations (API Gateway)
// -------------------------------------------------------------
async function loadDocuments() {
  const tbody = document.getElementById('documentsTableBody');
  tbody.innerHTML = `
    <tr>
      <td colspan="7" class="py-12 text-center text-slate-400">
        <i class="fa-solid fa-spinner fa-spin text-2xl mb-2 text-indigo-400"></i>
        <p>Loading documents via API Gateway...</p>
      </td>
    </tr>
  `;

  try {
    const apiBase = window.APP_CONFIG.API_BASE_URL;
    let url = `${apiBase}/files`;

    // Check if target employee filter is selected
    const employeeFilter = document.getElementById('employeeFilter');
    if (employeeFilter && employeeFilter.value) {
      url += `?employee_id=${encodeURIComponent(employeeFilter.value)}`;
    }

    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${currentUser.idToken}`
      }
    });

    const result = await response.json();

    if (!response.ok) {
      throw new Error(result.error?.message || 'Failed to list documents');
    }

    allDocuments = result.data?.documents || [];
    updateCategoryBadges();
    applyFilters();

  } catch (err) {
    console.error('Error listing documents:', err);
    tbody.innerHTML = `
      <tr>
        <td colspan="7" class="py-8 text-center text-rose-400">
          <i class="fa-solid fa-triangle-exclamation text-2xl mb-2"></i>
          <p>Failed to load files: ${err.message}</p>
        </td>
      </tr>
    `;
    showAlert(`Error: ${err.message}`, 'error');
  }
}

function setCategory(cat) {
  currentCategory = cat;
  document.querySelectorAll('.category-btn').forEach(btn => {
    if (btn.getAttribute('data-cat') === cat) {
      btn.classList.add('active');
    } else {
      btn.classList.remove('active');
    }
  });
  applyFilters();
}

function updateCategoryBadges() {
  const counts = {
    all: allDocuments.length,
    'offer-letter': 0,
    'contract': 0,
    'payslip': 0,
    'appraisal': 0,
    'compliance': 0
  };

  allDocuments.forEach(doc => {
    const type = doc.document_type;
    if (counts[type] !== undefined) {
      counts[type]++;
    }
  });

  for (const [key, count] of Object.entries(counts)) {
    const badge = document.getElementById(`badge-${key}`);
    if (badge) badge.innerText = count;
  }
}

function applyFilters() {
  const searchTerm = (document.getElementById('searchInput').value || '').toLowerCase().trim();
  const sortBy = document.getElementById('sortBy').value;

  let filtered = allDocuments.filter(doc => {
    // Category filter
    if (currentCategory !== 'all' && doc.document_type !== currentCategory) {
      return false;
    }
    // Search filter across filename, tags, employee_id, document_type
    if (searchTerm) {
      const matchName = (doc.filename || '').toLowerCase().includes(searchTerm);
      const matchType = (doc.document_type || '').toLowerCase().includes(searchTerm);
      const matchEmp = (doc.employee_id || '').toLowerCase().includes(searchTerm);
      const matchTags = (doc.tags || []).some(t => t.toLowerCase().includes(searchTerm));
      if (!matchName && !matchType && !matchEmp && !matchTags) {
        return false;
      }
    }
    return true;
  });

  // Sorting
  filtered.sort((a, b) => {
    if (sortBy === 'date-asc') {
      return (a.upload_timestamp || '').localeCompare(b.upload_timestamp || '');
    } else if (sortBy === 'filename') {
      return (a.filename || '').localeCompare(b.filename || '');
    } else if (sortBy === 'type') {
      return (a.document_type || '').localeCompare(b.document_type || '');
    } else {
      // date-desc default
      return (b.upload_timestamp || '').localeCompare(a.upload_timestamp || '');
    }
  });

  renderDocumentRows(filtered);
}

function renderDocumentRows(docs) {
  const tbody = document.getElementById('documentsTableBody');
  const emptyState = document.getElementById('emptyState');

  if (docs.length === 0) {
    tbody.innerHTML = '';
    emptyState.classList.remove('hidden');
    return;
  }

  emptyState.classList.add('hidden');

  tbody.innerHTML = docs.map(doc => {
    const dateStr = doc.upload_timestamp ? new Date(doc.upload_timestamp).toLocaleString() : 'N/A';
    const tagHtml = (doc.tags || []).map(t => `<span class="tag-pill">${escapeHtml(t)}</span>`).join(' ');
    
    let iconClass = 'fa-file-pdf text-rose-400';
    if (doc.filename.endsWith('.docx')) iconClass = 'fa-file-word text-blue-400';
    else if (doc.filename.endsWith('.xlsx')) iconClass = 'fa-file-excel text-emerald-400';
    else if (doc.filename.match(/\.(png|jpg|jpeg)$/)) iconClass = 'fa-file-image text-amber-400';

    return `
      <tr class="hover:bg-slate-750 transition group">
        <td class="py-3.5 px-4">
          <div class="flex items-center space-x-3">
            <i class="fa-solid ${iconClass} text-xl"></i>
            <div>
              <div class="font-semibold text-white group-hover:text-indigo-300 transition">${escapeHtml(doc.filename)}</div>
              <div class="text-[11px] text-slate-400 font-mono">${escapeHtml(doc.document_id)}</div>
            </div>
          </div>
        </td>
        <td class="py-3.5 px-4">
          <span class="text-xs font-semibold px-2.5 py-1 rounded-md bg-slate-700/60 text-slate-200 border border-slate-600/50">
            ${escapeHtml(doc.document_type)}
          </span>
        </td>
        <td class="py-3.5 px-4">
          <span class="font-semibold text-sky-400 text-xs">${escapeHtml(doc.employee_id)}</span>
        </td>
        <td class="py-3.5 px-4 text-xs text-slate-300">
          ${escapeHtml(doc.uploaded_by || 'System')}
        </td>
        <td class="py-3.5 px-4 text-xs text-slate-400 whitespace-nowrap">
          ${dateStr}
        </td>
        <td class="py-3.5 px-4">
          <div class="flex flex-wrap gap-1">${tagHtml || '<span class="text-slate-600 text-xs">—</span>'}</div>
        </td>
        <td class="py-3.5 px-4 text-center whitespace-nowrap">
          <div class="flex items-center justify-center space-x-2">
            <!-- Download Button -->
            <button onclick="downloadDocument('${doc.document_id}')" title="Download via Pre-signed URL"
              class="p-2 bg-indigo-600/20 hover:bg-indigo-600/40 text-indigo-300 rounded-lg transition border border-indigo-500/30">
              <i class="fa-solid fa-download"></i>
            </button>
            <!-- Version History Button -->
            <button onclick="viewVersions('${doc.document_id}', '${escapeHtml(doc.filename)}')" title="View S3 Versions"
              class="p-2 bg-amber-600/20 hover:bg-amber-600/40 text-amber-300 rounded-lg transition border border-amber-500/30">
              <i class="fa-solid fa-clock-rotate-left"></i>
            </button>
            <!-- Soft Delete Button -->
            <button onclick="softDeleteDocument('${doc.document_id}', '${escapeHtml(doc.filename)}')" title="Soft Delete"
              class="p-2 bg-rose-600/20 hover:bg-rose-600/40 text-rose-300 rounded-lg transition border border-rose-500/30">
              <i class="fa-solid fa-trash-can"></i>
            </button>
          </div>
        </td>
      </tr>
    `;
  }).join('');
}

// -------------------------------------------------------------
// Pre-signed Upload Flow
// -------------------------------------------------------------
function openUploadModal() {
  document.getElementById('uploadModal').classList.remove('hidden');
  document.getElementById('uploadProgress').classList.add('hidden');
}

function closeUploadModal() {
  document.getElementById('uploadModal').classList.add('hidden');
  document.getElementById('uploadForm').reset();
  if (currentUser) {
    document.getElementById('uploadEmployeeId').value = currentUser.employee_id;
  }
}

async function handleUpload(e) {
  e.preventDefault();
  const fileInput = document.getElementById('uploadFileInput');
  const file = fileInput.files[0];
  if (!file) {
    showAlert('Please select a file to upload.', 'error');
    return;
  }

  // Client side 10MB guard
  if (file.size > 10 * 1024 * 1024) {
    showAlert('File size exceeds the 10MB limit.', 'error');
    return;
  }

  const employeeId = document.getElementById('uploadEmployeeId').value.trim();
  const docType = document.getElementById('uploadDocType').value;
  const tagsStr = document.getElementById('uploadTags').value.trim();
  const tags = tagsStr ? tagsStr.split(',').map(t => t.trim()).filter(Boolean) : [];

  const progress = document.getElementById('uploadProgress');
  const progressText = document.getElementById('uploadProgressText');
  const submitBtn = document.getElementById('submitUploadBtn');

  progress.classList.remove('hidden');
  submitBtn.disabled = true;

  try {
    progressText.innerText = 'Step 1/2: Generating pre-signed upload URL...';
    const apiBase = window.APP_CONFIG.API_BASE_URL;

    const reqBody = {
      employee_id: employeeId,
      document_type: docType,
      filename: file.name,
      content_type: file.type || 'application/octet-stream',
      tags: tags
    };

    const presignedRes = await fetch(`${apiBase}/upload`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${currentUser.idToken}`
      },
      body: JSON.stringify(reqBody)
    });

    const presignedData = await presignedRes.json();
    if (!presignedRes.ok) {
      throw new Error(presignedData.error?.message || 'Failed to initialize upload');
    }

    const uploadUrl = presignedData.data.upload_url;

    progressText.innerText = 'Step 2/2: Uploading directly to S3 with KMS encryption...';

    // Direct PUT to S3 using pre-signed URL
    const s3Res = await fetch(uploadUrl, {
      method: 'PUT',
      headers: {
        'Content-Type': file.type || 'application/octet-stream'
      },
      body: file
    });

    if (!s3Res.ok) {
      throw new Error(`S3 upload rejected (HTTP ${s3Res.status})`);
    }

    closeUploadModal();
    showAlert(`Successfully uploaded "${file.name}"!`, 'success');
    await loadDocuments();

  } catch (err) {
    console.error('Upload failed:', err);
    showAlert(`Upload failed: ${err.message}`, 'error');
  } finally {
    progress.classList.add('hidden');
    submitBtn.disabled = false;
  }
}

// -------------------------------------------------------------
// Pre-signed Download Flow
// -------------------------------------------------------------
async function downloadDocument(docId, versionId = null) {
  try {
    const apiBase = window.APP_CONFIG.API_BASE_URL;
    let url = `${apiBase}/download/${docId}`;
    if (versionId) {
      url += `?version_id=${encodeURIComponent(versionId)}`;
    }

    const res = await fetch(url, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${currentUser.idToken}`
      }
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.error?.message || 'Download authorization failed');
    }

    const downloadUrl = data.data.download_url;
    // Trigger download via anchor
    const a = document.createElement('a');
    a.href = downloadUrl;
    a.download = data.data.filename || 'document.pdf';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);

    showAlert(`Generated secure 15-minute download link for "${data.data.filename}".`, 'success');

  } catch (err) {
    console.error('Download error:', err);
    showAlert(`Download error: ${err.message}`, 'error');
  }
}

// -------------------------------------------------------------
// Soft Delete Flow
// -------------------------------------------------------------
async function softDeleteDocument(docId, filename) {
  if (!confirm(`Are you sure you want to delete "${filename}"?\n\nNote: This performs a soft-delete in DynamoDB while preserving the immutable physical S3 object.`)) {
    return;
  }

  try {
    const apiBase = window.APP_CONFIG.API_BASE_URL;
    const res = await fetch(`${apiBase}/files/${docId}`, {
      method: 'DELETE',
      headers: {
        'Authorization': `Bearer ${currentUser.idToken}`
      }
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.error?.message || 'Delete operation failed');
    }

    showAlert(`Document "${filename}" soft-deleted successfully.`, 'success');
    await loadDocuments();

  } catch (err) {
    console.error('Delete error:', err);
    showAlert(`Delete error: ${err.message}`, 'error');
  }
}

// -------------------------------------------------------------
// S3 Version History Flow
// -------------------------------------------------------------
async function viewVersions(docId, filename) {
  const modal = document.getElementById('versionModal');
  const nameEl = document.getElementById('versionModalDocName');
  const tbody = document.getElementById('versionTableBody');

  nameEl.innerText = `${filename} (${docId})`;
  tbody.innerHTML = `
    <tr>
      <td colspan="5" class="py-6 text-center text-slate-400">
        <i class="fa-solid fa-spinner fa-spin mr-2"></i> Querying S3 Version History...
      </td>
    </tr>
  `;
  modal.classList.remove('hidden');

  try {
    const apiBase = window.APP_CONFIG.API_BASE_URL;
    const res = await fetch(`${apiBase}/files/${docId}/versions`, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${currentUser.idToken}`
      }
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.error?.message || 'Failed to retrieve version history');
    }

    const versions = data.data?.versions || [];
    if (versions.length === 0) {
      tbody.innerHTML = `
        <tr>
          <td colspan="5" class="py-6 text-center text-slate-400">
            No version history available for this document.
          </td>
        </tr>
      `;
      return;
    }

    tbody.innerHTML = versions.map((v, idx) => {
      const isLatest = v.is_latest;
      const sizeKb = (v.size / 1024).toFixed(1);
      const modifiedStr = v.last_modified ? new Date(v.last_modified).toLocaleString() : 'N/A';
      
      return `
        <tr class="hover:bg-slate-750 transition">
          <td class="py-2.5 px-3 font-mono text-[11px] text-slate-300">
            ${escapeHtml(v.version_id.substring(0, 16))}...
          </td>
          <td class="py-2.5 px-3 text-slate-400 whitespace-nowrap">
            ${modifiedStr}
          </td>
          <td class="py-2.5 px-3 text-slate-300">
            ${sizeKb} KB
          </td>
          <td class="py-2.5 px-3 text-center">
            ${isLatest ? 
              '<span class="px-2 py-0.5 rounded-full text-[10px] font-semibold bg-emerald-950 text-emerald-400 border border-emerald-800">Current</span>' : 
              '<span class="px-2 py-0.5 rounded-full text-[10px] font-semibold bg-slate-700 text-slate-400">Archived</span>'
            }
          </td>
          <td class="py-2.5 px-3 text-right">
            <button onclick="downloadDocument('${docId}', '${v.version_id}')"
              class="px-2.5 py-1 bg-indigo-600/30 hover:bg-indigo-600 text-indigo-200 text-xs rounded transition">
              <i class="fa-solid fa-download"></i> Get Version
            </button>
          </td>
        </tr>
      `;
    }).join('');

  } catch (err) {
    console.error('Versions error:', err);
    tbody.innerHTML = `
      <tr>
        <td colspan="5" class="py-6 text-center text-rose-400">
          Failed to fetch versions: ${err.message}
        </td>
      </tr>
    `;
  }
}

function closeVersionModal() {
  document.getElementById('versionModal').classList.add('hidden');
}

function escapeHtml(text) {
  if (!text) return '';
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
