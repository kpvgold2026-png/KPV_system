var _editingUserRow = null;

async function loadUserSetting() {
  try {
    showLoading();
    var data = await fetchSheetData('_database!A33:D100');
    var tbody = document.getElementById('userSettingTable');
    if (!data || data.length <= 1) {
      tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:40px;">No users found</td></tr>';
      hideLoading();
      return;
    }
    var rows = data.slice(1).filter(function(r) { return String(r[2] || '').trim() !== ''; });
    if (rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:40px;">No users found</td></tr>';
      hideLoading();
      return;
    }
    tbody.innerHTML = rows.map(function(row, idx) {
      var sheetRow = idx + 34;
      return '<tr>' +
        '<td>' + (row[0] || '') + '</td>' +
        '<td>' + (row[1] || '') + '</td>' +
        '<td>' + (row[2] || '') + '</td>' +
        '<td>' + (row[3] || '') + '</td>' +
        '<td>' +
        '<button class="btn-action" onclick="editUser(' + sheetRow + ',\'' + encodeURIComponent(row[0]) + '\',\'' + encodeURIComponent(row[1]) + '\',\'' + encodeURIComponent(row[2]) + '\',\'' + encodeURIComponent(row[3]) + '\')" style="margin-right:5px;">✏️</button>' +
        '<button class="btn-action" onclick="deleteUser(' + sheetRow + ',\'' + encodeURIComponent(row[2]) + '\')" style="background:#f44336;">🗑️</button>' +
        '</td></tr>';
    }).join('');
    hideLoading();
  } catch(e) {
    console.error('Error loading user setting:', e);
    hideLoading();
  }
}

function openAddUserModal() {
  _editingUserRow = null;
  document.getElementById('addUserModalTitle').textContent = 'Add User';
  document.getElementById('userFormRole').value = 'Sales';
  document.getElementById('userFormName').value = '';
  document.getElementById('userFormUsername').value = '';
  document.getElementById('userFormPass').value = '';
  document.getElementById('userFormUsername').disabled = false;
  openModal('addUserModal');
}

function editUser(sheetRow, roleEnc, nameEnc, usernameEnc, passEnc) {
  _editingUserRow = sheetRow;
  document.getElementById('addUserModalTitle').textContent = 'Edit User';
  document.getElementById('userFormRole').value = decodeURIComponent(roleEnc);
  document.getElementById('userFormName').value = decodeURIComponent(nameEnc);
  document.getElementById('userFormUsername').value = decodeURIComponent(usernameEnc);
  document.getElementById('userFormPass').value = decodeURIComponent(passEnc);
  document.getElementById('userFormUsername').disabled = true;
  openModal('addUserModal');
}

async function saveUser() {
  var role = document.getElementById('userFormRole').value.trim();
  var name = document.getElementById('userFormName').value.trim();
  var username = document.getElementById('userFormUsername').value.trim();
  var pass = document.getElementById('userFormPass').value.trim();
  if (!role || !name || !username || !pass) {
    alert('กรุณากรอกข้อมูลให้ครบ');
    return;
  }
  try {
    showLoading();
    var result = await callAppsScript('SAVE_USER', {
      row: _editingUserRow || 0,
      role: role,
      name: name,
      username: username,
      pass: pass
    });
    if (result.success) {
      alert('✅ ' + result.message);
      closeModal('addUserModal');
      await fetchUsersFromSheet();
      loadUserSetting();
    } else {
      alert('❌ ' + result.message);
    }
    hideLoading();
  } catch(e) {
    alert('❌ ' + e.message);
    hideLoading();
  }
}

async function deleteUser(sheetRow, usernameEnc) {
  var username = decodeURIComponent(usernameEnc);
  if (username === currentUser.username) {
    alert('❌ ไม่สามารถลบตัวเองได้');
    return;
  }
  if (!confirm('ยืนยันลบ user "' + username + '" ?')) return;
  try {
    showLoading();
    var result = await callAppsScript('DELETE_USER', { row: sheetRow });
    if (result.success) {
      alert('✅ ' + result.message);
      await fetchUsersFromSheet();
      loadUserSetting();
    } else {
      alert('❌ ' + result.message);
    }
    hideLoading();
  } catch(e) {
    alert('❌ ' + e.message);
    hideLoading();
  }
}
