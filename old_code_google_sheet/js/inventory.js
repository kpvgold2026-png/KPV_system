async function loadInventory() {
  try {
    showLoading();
    const data = await fetchSheetData('Inventory!A:R');
    const tbody = document.getElementById('inventoryTable');
    
    if (data.length <= 1) {
      tbody.innerHTML = '<tr><td colspan="14" style="text-align: center; padding: 40px;">No inventory records</td></tr>';
      hideLoading();
      return;
    }
    
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const todayStr = getTodayLocalStr();
    
    const rows = data.slice(1);
    
    let todayRows = [];
    let lastYesterdayRow = null;
    
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      const dateValue = row[16];
      
      if (!dateValue) continue;
      
      let rowDate;
      if (dateValue instanceof Date) {
        rowDate = dateValue;
      } else if (typeof dateValue === 'string') {
        if (dateValue.includes('/')) {
          const parts = dateValue.split(' ')[0].split('/');
          const day = parseInt(parts[0]);
          const month = parseInt(parts[1]) - 1;
          const year = parseInt(parts[2]);
          rowDate = new Date(year, month, day);
        } else {
          rowDate = new Date(dateValue);
        }
      } else {
        rowDate = new Date(dateValue);
      }
      
      rowDate.setHours(0, 0, 0, 0);
      const rowDateStr = rowDate.toISOString().split('T')[0];
      
      if (rowDateStr === todayStr) {
        todayRows.push(row);
      } else if (rowDateStr < todayStr) {
        lastYesterdayRow = row;
      }
    }
    
    const displayRows = lastYesterdayRow ? [lastYesterdayRow, ...todayRows] : todayRows;
    
    if (displayRows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="14" style="text-align: center; padding: 40px;">No records for today</td></tr>';
      hideLoading();
      return;
    }
    
    tbody.innerHTML = displayRows.map(row => `
      <tr>
        <td>${row[0]}</td>
        <td>${row[3]}</td>
        <td>${formatNumber(row[4])}</td>
        <td>${formatNumber(row[5])}</td>
        <td>${formatNumber(row[6])}</td>
        <td>${formatNumber(row[7])}</td>
        <td>${formatNumber(row[8])}</td>
        <td>${formatNumber(row[9])}</td>
        <td>${formatNumber(row[10])}</td>
        <td>${formatNumber(row[11])}</td>
        <td>${formatNumber(row[12])}</td>
        <td>${formatNumber(row[13])}</td>
        <td>${formatNumber(row[14])}</td>
        <td>${formatNumber(row[15])}</td>
      </tr>
    `).join('');
    
    hideLoading();
  } catch (error) {
    console.error('Error loading inventory:', error);
    hideLoading();
  }
}

async function openTransferModal() {
  document.getElementById('transferOldProducts').innerHTML = '';
  addTransferProduct();
  
  await loadStockInModal();
  
  openModal('transferModal');
}

async function loadStockInModal() {
  try {
    const data = await fetchSheetData('_database!A10:G10');
    
    if (data.length === 0) {
      document.getElementById('stockSummaryInModal').innerHTML = '<tr><td colspan="3" style="text-align: center; padding: 20px;">No stock data</td></tr>';
      return;
    }
    
    const oldGoldRow = data[0];
    const products = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06', 'G07'];
    
    const oldStockRows = products.map((productId, index) => {
      const qty = parseFloat(oldGoldRow[index]) || 0;
      if (qty <= 0) return null;
      
      const product = FIXED_PRODUCTS.find(p => p.id === productId);
      return `
        <tr>
          <td>${productId}</td>
          <td>${product ? product.name : 'Unknown'}</td>
          <td>${qty}</td>
        </tr>
      `;
    }).filter(row => row !== null).join('');
    
    document.getElementById('stockSummaryInModal').innerHTML = oldStockRows || '<tr><td colspan="3" style="text-align: center; padding: 20px;">No OLD stock</td></tr>';
  } catch (error) {
    console.error('Error loading stock in modal:', error);
  }
}

function addTransferProduct() {
  const container = document.getElementById('transferOldProducts');
  const row = document.createElement('div');
  row.className = 'product-row';
  row.style.cssText = 'display: flex; gap: 10px; margin-bottom: 10px; align-items: center;';
  
  row.innerHTML = `
    <select class="form-input" style="flex: 1;">
      ${FIXED_PRODUCTS.map(p => `<option value="${p.id}">${p.name}</option>`).join('')}
    </select>
    <input type="number" class="form-input" placeholder="Quantity" min="1" style="width: 150px;">
    <button class="btn-danger" onclick="this.parentElement.remove()" style="padding: 8px 15px;">Remove</button>
  `;
  
  container.appendChild(row);
}

async function confirmTransfer() {
  try {
    const rows = document.querySelectorAll('#transferOldProducts .product-row');
    const items = [];
    for (const row of rows) {
      const select = row.querySelector('select');
      const input = row.querySelector('input');
      const productId = select.value;
      const qty = parseInt(input.value);
      if (!qty || qty <= 0) { alert('กรุณากรอกจำนวนให้ถูกต้อง'); return; }
      items.push({ productId, qty });
    }
    if (items.length === 0) { alert('กรุณาเพิ่มสินค้าอย่างน้อย 1 รายการ'); return; }
    if (!confirm('ยืนยันการโอนทองเก่าไปทองใหม่ ' + items.length + ' รายการ?')) return;
    showLoading();
    const result = await executeGoogleScript('TRANSFER_OLD_TO_NEW', { items: JSON.stringify(mergeItems(items)) });
    if (result.success) {
      showToast('✅ ' + result.message);
      closeModal('transferModal');
      if (typeof loadStockOld === 'function') await loadStockOld();
      if (typeof loadPendingTransferCount === 'function') loadPendingTransferCount();
    } else {
      alert('❌ ' + result.message);
    }
    hideLoading();
  } catch (error) {
    console.error('Error transferring:', error);
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    hideLoading();
  }
}

function openStockInModal() {
  document.getElementById('stockInProducts').innerHTML = '';
  document.getElementById('stockInNote').value = '';
  addStockInProduct();
  openModal('stockInModal');
}

function addStockInProduct() {
  const container = document.getElementById('stockInProducts');
  const row = document.createElement('div');
  row.className = 'product-row';
  row.style.cssText = 'display: flex; gap: 10px; margin-bottom: 10px; align-items: center;';
  
  row.innerHTML = `
    <select class="form-input" style="flex: 1;">
      ${FIXED_PRODUCTS.map(p => `<option value="${p.id}">${p.name}</option>`).join('')}
    </select>
    <input type="number" class="form-input" placeholder="Quantity" min="1" style="width: 150px;">
    <button class="btn-danger" onclick="this.parentElement.remove()" style="padding: 8px 15px;">Remove</button>
  `;
  
  container.appendChild(row);
}

async function confirmStockIn() {
  try {
    const rows = document.querySelectorAll('#stockInProducts .product-row');
    const items = [];
    
    for (const row of rows) {
      const select = row.querySelector('select');
      const input = row.querySelector('input');
      const productId = select.value;
      const qty = parseInt(input.value);
      
      if (!qty || qty <= 0) {
        alert('กรุณากรอกจำนวนให้ถูกต้อง');
        return;
      }
      
      items.push({ productId, qty });
    }
    
    if (items.length === 0) {
      alert('กรุณาเพิ่มสินค้าอย่างน้อย 1 รายการ');
      return;
    }
    
    const note = document.getElementById('stockInNote').value.trim();
    
    if (!confirm(`ยืนยันการ Stock In ${items.length} รายการ?`)) {
      return;
    }
    
    showLoading();
    
    const result = await executeGoogleScript('STOCK_IN', {
      items: JSON.stringify(mergeItems(items)),
      note: note
    });
    
    if (result.success) {
      showToast('✅ ' + result.message);
      closeModal('stockInModal');
      await loadInventory();
    } else {
      alert('❌ ' + result.message);
    }
    
    hideLoading();
  } catch (error) {
    console.error('Error stock in:', error);
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    hideLoading();
  }
}

function openStockOutModal() {
  document.getElementById('stockOutProducts').innerHTML = '';
  document.getElementById('stockOutNote').value = '';
  addStockOutProduct();
  openModal('stockOutModal');
}

function addStockOutProduct() {
  const container = document.getElementById('stockOutProducts');
  const row = document.createElement('div');
  row.className = 'product-row';
  row.style.cssText = 'display: flex; gap: 10px; margin-bottom: 10px; align-items: center;';
  
  row.innerHTML = `
    <select class="form-input" style="flex: 1;">
      ${FIXED_PRODUCTS.map(p => `<option value="${p.id}">${p.name}</option>`).join('')}
    </select>
    <input type="number" class="form-input" placeholder="Quantity" min="1" style="width: 150px;">
    <button class="btn-danger" onclick="this.parentElement.remove()" style="padding: 8px 15px;">Remove</button>
  `;
  
  container.appendChild(row);
}

async function confirmStockOut() {
  try {
    const rows = document.querySelectorAll('#stockOutProducts .product-row');
    const items = [];
    for (const row of rows) {
      const select = row.querySelector('select');
      const input = row.querySelector('input');
      const productId = select.value;
      const qty = parseInt(input.value);
      if (!qty || qty <= 0) { alert('กรุณากรอกจำนวนให้ถูกต้อง'); return; }
      items.push({ productId, qty });
    }
    if (items.length === 0) { alert('กรุณาเพิ่มสินค้าอย่างน้อย 1 รายการ'); return; }
    const note = document.getElementById('stockOutNote').value.trim();
    if (!confirm('ยืนยันการ Stock Out (OLD) ' + items.length + ' รายการ?')) return;
    showLoading();
    const result = await executeGoogleScript('STOCK_OUT_OLD', { items: JSON.stringify(mergeItems(items)), note: note });
    if (result.success) {
      showToast('✅ ' + result.message);
      closeModal('stockOutModal');
      if (typeof loadStockOld === 'function') await loadStockOld();
    } else {
      alert('❌ ' + result.message);
    }
    hideLoading();
  } catch (error) {
    console.error('Error stock out:', error);
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    hideLoading();
  }
}
