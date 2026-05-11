var _editingUserId = null;

async function loadUserSetting() {
  try {
    showLoading();
    var result = await dbRpc('list_users', {});
    hideLoading();
    var tbody = document.getElementById('userSettingTable');

    if (!result || !result.success || !result.data || result.data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:40px;">No users found</td></tr>';
      return;
    }

    tbody.innerHTML = result.data.map(function(u) {
      return '<tr>' +
        '<td>' + u.role + '</td>' +
        '<td>' + (u.nickname || '') + '</td>' +
        '<td>' + (u.username || '') + '</td>' +
        '<td>••••••••</td>' +
        '<td>' +
        '<button class="btn-action" onclick="editUser(\'' + u.id + '\',\'' + encodeURIComponent(u.role) + '\',\'' + encodeURIComponent(u.nickname || '') + '\',\'' + encodeURIComponent(u.username || '') + '\')" style="margin-right:5px;">✏️</button>' +
        '<button class="btn-action" onclick="deleteUser(\'' + u.id + '\',\'' + encodeURIComponent(u.username || '') + '\')" style="background:#f44336;">🗑️</button>' +
        '</td></tr>';
    }).join('');
  } catch(e) {
    console.error('Error loading user setting:', e);
    hideLoading();
  }
}

function openAddUserModal() {
  _editingUserId = null;
  document.getElementById('addUserModalTitle').textContent = 'Add User';
  document.getElementById('userFormRole').value = 'Sales';
  document.getElementById('userFormName').value = '';
  document.getElementById('userFormUsername').value = '';
  document.getElementById('userFormPass').value = '';
  document.getElementById('userFormUsername').disabled = false;
  openModal('addUserModal');
}

function editUser(userId, roleEnc, nameEnc, usernameEnc) {
  _editingUserId = userId;
  document.getElementById('addUserModalTitle').textContent = 'Edit User';
  document.getElementById('userFormRole').value = decodeURIComponent(roleEnc);
  document.getElementById('userFormName').value = decodeURIComponent(nameEnc);
  document.getElementById('userFormUsername').value = decodeURIComponent(usernameEnc);
  document.getElementById('userFormPass').value = '';
  document.getElementById('userFormUsername').disabled = false;
  openModal('addUserModal');
}

async function saveUser() {
  var role = document.getElementById('userFormRole').value.trim();
  var name = document.getElementById('userFormName').value.trim();
  var username = document.getElementById('userFormUsername').value.trim();
  var pass = document.getElementById('userFormPass').value.trim();

  if (!role || !name || !username) {
    alert('กรุณากรอกข้อมูลให้ครบ');
    return;
  }
  if (!_editingUserId && !pass) {
    alert('กรุณากรอกรหัสผ่าน');
    return;
  }

  try {
    showLoading();
    var result = await dbRpc('save_user', {
      p_user_id: _editingUserId,
      p_role: role,
      p_nickname: name,
      p_username: username,
      p_password: pass
    });
    hideLoading();
    if (result && result.success) {
      alert('✅ ' + result.message);
      closeModal('addUserModal');
      loadUserSetting();
    } else {
      alert('❌ ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch(e) {
    hideLoading();
    alert('❌ ' + e.message);
  }
}

async function deleteUser(userId, usernameEnc) {
  var username = decodeURIComponent(usernameEnc);
  if (!confirm('ยืนยันลบ user "' + username + '" ?')) return;
  try {
    showLoading();
    var result = await dbRpc('delete_user_soft', { p_user_id: userId });
    hideLoading();
    if (result && result.success) {
      alert('✅ ' + result.message);
      loadUserSetting();
    } else {
      alert('❌ ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch(e) {
    hideLoading();
    alert('❌ ' + e.message);
  }
}
