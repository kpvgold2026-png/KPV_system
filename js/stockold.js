var stockOldDateFrom = null;
var stockOldDateTo = null;

async function loadStockOld() {
  var isFiltered = stockOldDateFrom && stockOldDateTo;
  var isToday = false;
  if (isFiltered) {
    var td = getTodayDateString();
    isToday = (stockOldDateFrom === td && stockOldDateTo === td);
  }

  var _tblSpinnerOld = '<div style="display:inline-block;width:20px;height:20px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div>';
  document.getElementById('stockOldSummaryTable').innerHTML = '<tr><td colspan="6" style="text-align:center;padding:20px;">' + _tblSpinnerOld + '</td></tr>';
  document.getElementById('stockOldMovementTable').innerHTML = '<tr><td colspan="9" style="text-align:center;padding:20px;">' + _tblSpinnerOld + '</td></tr>';
  document.getElementById('stockOldGoldG').textContent = '...';
  document.getElementById('stockOldCostValue').textContent = '...';

  if (!isFiltered || isToday) {
    await loadStockOldSummary();
    await loadStockOldMoves();
  } else {
    await loadStockOldFiltered();
  }
}

async function loadStockOldSummary() {
  try {
    var res = await dbRpc('get_stock_summary', { p_gold_type: 'OLD' });
    var carry = res && res.carry ? res.carry : {};
    var qtyIn = res && res.in ? res.in : {};
    var qtyOut = res && res.out ? res.out : {};
    FIXED_PRODUCTS.forEach(function(p) {
      if (carry[p.id] === undefined) carry[p.id] = 0;
      if (qtyIn[p.id] === undefined) qtyIn[p.id] = 0;
      if (qtyOut[p.id] === undefined) qtyOut[p.id] = 0;
    });
    renderStockOldSummary(carry, qtyIn, qtyOut);
  } catch(e) { console.error('Error loading stock old summary:', e); }
}

async function loadStockOldMoves() {
  try {
    var today = getTodayDateString();
    var res = await dbRpc('get_stock_moves', {
      p_gold_type: 'OLD',
      p_date_from: today,
      p_date_to: today
    });
    var prevW = res && res.prevW ? parseFloat(res.prevW) : 0;
    var prevC = res && res.prevC ? parseFloat(res.prevC) : 0;
    var moves = res && res.moves ? res.moves : [];
    renderStockOldMovements(moves, prevW, prevC, true);
  } catch(e) { console.error('Error loading stock old moves:', e); }
}

async function loadStockOldFiltered() {
  try {
    var res = await dbRpc('get_stock_moves', {
      p_gold_type: 'OLD',
      p_date_from: stockOldDateFrom,
      p_date_to: stockOldDateTo
    });
    var moves = res && res.moves ? res.moves : [];
    var carry = {}, qtyIn = {}, qtyOut = {};
    FIXED_PRODUCTS.forEach(function(p) { carry[p.id] = 0; qtyIn[p.id] = 0; qtyOut[p.id] = 0; });
    renderStockOldSummary(carry, qtyIn, qtyOut);
    renderFilteredMoves('stockOldMovementTable', moves, stockOldDateFrom, stockOldDateTo);
    document.getElementById('stockOldGoldG').textContent = '-';
    document.getElementById('stockOldCostValue').textContent = '-';
  } catch(e) { console.error('Error loading stock old filtered:', e); }
}

function renderStockOldSummary(carry, qtyIn, qtyOut) {
  document.getElementById('stockOldSummaryTable').innerHTML = FIXED_PRODUCTS.map(function(p) {
    var c = parseFloat(carry[p.id]) || 0;
    var i = parseFloat(qtyIn[p.id]) || 0;
    var o = parseFloat(qtyOut[p.id]) || 0;
    return '<tr><td>' + p.id + '</td><td>' + p.name + '</td><td>' + c + '</td>' +
      '<td style="color:#4caf50;">' + i + '</td>' +
      '<td style="color:#f44336;">' + o + '</td>' +
      '<td style="font-weight:bold;">' + (c + i - o) + '</td></tr>';
  }).join('');
}

function renderStockOldMovements(moves, prevW, prevC, showRunning) {
  var todayMovements = moves.map(function(m) {
    var goldG = parseFloat(m.goldG) || 0;
    var price = parseFloat(m.price) || 0;
    var gIn = m.dir === 'IN' ? goldG : 0;
    var gOut = m.dir === 'OUT' ? goldG : 0;
    var pIn = m.dir === 'IN' ? price : 0;
    var pOut = m.dir === 'OUT' ? price : 0;
    return { id: m.id, type: m.type, goldIn: gIn, goldOut: gOut, priceIn: pIn, priceOut: pOut };
  });

  var w = prevW, c = prevC;
  todayMovements.forEach(function(m) {
    w += m.goldIn - m.goldOut;
    c += m.priceIn - m.priceOut;
    m.w = w;
    m.c = c;
  });

  document.getElementById('stockOldGoldG').textContent = formatWeight(w) + ' g';
  document.getElementById('stockOldCostValue').textContent = formatNumber(Math.round(c)) + ' LAK';
  window._stockOldLatest = { goldG: w, cost: c };

  var movBody = document.getElementById('stockOldMovementTable');
  var rows = '';

  if (prevW !== 0 || prevC !== 0) {
    rows += '<tr style="background:rgba(212,175,55,0.06);">' +
      '<td colspan="4" style="font-style:italic;color:var(--gold-primary);">📌 ยกมา</td>' +
      '<td style="font-weight:bold;">' + formatWeight(prevW) + '</td>' +
      '<td colspan="2"></td>' +
      '<td style="font-weight:bold;">' + formatNumber(Math.round(prevC)) + '</td>' +
      '<td></td></tr>';
  }

  if (todayMovements.length === 0 && rows === '') {
    movBody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:40px;">ไม่มีรายการวันนี้</td></tr>';
    return;
  }

  rows += todayMovements.map(function(m) { return '<tr>' +
    '<td>' + m.id + '</td>' +
    '<td><span class="status-badge">' + m.type + '</span></td>' +
    '<td style="color:#4caf50;">' + (m.goldIn > 0 ? formatWeight(m.goldIn) : '-') + '</td>' +
    '<td style="color:#f44336;">' + (m.goldOut > 0 ? formatWeight(m.goldOut) : '-') + '</td>' +
    '<td style="font-weight:bold;">' + formatWeight(m.w) + '</td>' +
    '<td style="color:#4caf50;">' + (m.priceIn > 0 ? formatNumber(m.priceIn) : '-') + '</td>' +
    '<td style="color:#f44336;">' + (m.priceOut > 0 ? formatNumber(m.priceOut) : '-') + '</td>' +
    '<td style="font-weight:bold;">' + formatNumber(Math.round(m.c)) + '</td>' +
    '<td><button class="btn-action" onclick="viewBillDetail(\'' + m.id + '\',\'' + m.type + '\')">📋</button></td>' +
    '</tr>'; }).join('');

  movBody.innerHTML = rows;
}

function resetStockOldFilter() {
  var today = getTodayDateString();
  document.getElementById('stockOldDateFrom').value = today;
  document.getElementById('stockOldDateTo').value = today;
  stockOldDateFrom = today;
  stockOldDateTo = today;
  loadStockOld();
}

document.addEventListener('DOMContentLoaded', function() {
  var f = document.getElementById('stockOldDateFrom');
  var t = document.getElementById('stockOldDateTo');
  if (f && t) {
    f.addEventListener('change', function() { stockOldDateFrom = this.value; stockOldDateTo = t.value || stockOldDateFrom; if (!t.value) t.value = stockOldDateTo; if (stockOldDateFrom && stockOldDateTo) loadStockOld(); });
    t.addEventListener('change', function() { stockOldDateTo = this.value; stockOldDateFrom = f.value || stockOldDateTo; if (!f.value) f.value = stockOldDateFrom; if (stockOldDateFrom && stockOldDateTo) loadStockOld(); });
  }
});

async function viewBillDetail(id, type) {
  try {
    showLoading();

    var html = '<div style="margin-bottom:15px;"><span style="font-size:12px;color:var(--text-secondary);">Reference ID</span><br><span style="font-size:18px;font-weight:bold;color:var(--gold-primary);">' + id + '</span></div>';
    html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:15px;">';
    html += '<div><span style="color:var(--text-secondary);font-size:12px;">ประเภท</span><br><span class="status-badge">' + type + '</span></div>';

    var txTypes = ['SELL', 'BUYBACK', 'TRADEIN', 'EXCHANGE', 'WITHDRAW'];
    var isStockMove = (type === 'STOCK_IN' || type === 'STOCK_OUT' || type === 'TRANSFER');

    if (txTypes.indexOf(type) !== -1 || txTypes.indexOf(type.replace('-', '')) !== -1) {
      var txRows = await dbSelect('transactions', {
        select: '*,items:transaction_items(product_id,qty,item_role)',
        filters: { id: 'eq.' + id },
        limit: 1,
        useCache: false
      });
      if (txRows && txRows.length > 0) {
        var row = txRows[0];
        var allItems = (row.items || []).map(function(i) { return { productId: i.product_id, qty: i.qty }; });
        html += '<div><span style="color:var(--text-secondary);font-size:12px;">สถานะ</span><br><span class="status-badge">' + (row.status || '-') + '</span></div></div>';
        html += '<div style="margin-bottom:15px;"><table class="data-table" style="width:100%;"><thead><tr><th>สินค้า</th><th>จำนวน</th></tr></thead><tbody>' + fmtItemsList(allItems) + '</tbody></table></div>';
        html += '<div class="stat-card" style="padding:10px;text-align:center;"><div style="color:var(--text-secondary);font-size:11px;">ยอดรวม</div><div style="font-weight:bold;font-size:18px;color:var(--gold-primary);">' + formatNumber(row.total) + ' LAK</div></div>';
      } else {
        html += '<div></div></div><p style="text-align:center;color:var(--text-secondary);">ไม่พบข้อมูล</p>';
      }
    } else if (isStockMove) {
      var moveDetail = await dbRpc('get_stock_move_detail', { p_ref_id: id });
      if (moveDetail && moveDetail.ref_id) {
        html += '<div><span style="color:var(--text-secondary);font-size:12px;">Direction</span><br><span class="status-badge">' + (moveDetail.direction || '') + '</span></div></div>';
        var items = moveDetail.items || [];
        html += '<div style="margin-bottom:15px;"><table class="data-table" style="width:100%;"><thead><tr><th>สินค้า</th><th>จำนวน</th></tr></thead><tbody>' + fmtItemsList(items) + '</tbody></table></div>';
        html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;">';
        html += '<div class="stat-card" style="padding:10px;"><div style="color:var(--text-secondary);font-size:11px;">น้ำหนัก</div><div style="font-weight:bold;">' + formatWeight(parseFloat(moveDetail.gold_g) || 0) + ' g</div></div>';
        html += '<div class="stat-card" style="padding:10px;"><div style="color:var(--text-secondary);font-size:11px;">มูลค่า</div><div style="font-weight:bold;color:var(--gold-primary);">' + formatNumber(parseFloat(moveDetail.price) || 0) + ' LAK</div></div></div>';

        if (moveDetail.note) {
          html += '<div style="margin-top:15px;padding:12px;background:rgba(255,255,255,0.05);border-radius:8px;border:1px solid var(--border-color);">';
          html += '<div style="font-size:12px;color:var(--text-secondary);margin-bottom:4px;">📝 Note</div>';
          html += '<div style="font-size:13px;">' + moveDetail.note + '</div>';
          html += '</div>';
        }
      } else {
        html += '<div></div></div><p style="text-align:center;color:var(--text-secondary);">ไม่พบข้อมูล</p>';
      }
    } else {
      html += '<div></div></div><p style="text-align:center;color:var(--text-secondary);">ไม่รองรับประเภทนี้</p>';
    }

    hideLoading();
    showBillModal(id, type, html);
  } catch(e) {
    hideLoading();
    showBillModal('Error', '', '<p style="color:#f44336;">' + e.message + '</p>');
  }
}

function fmtItemsList(items) {
  try {
    if (typeof items === 'string') items = JSON.parse(items);
    return (items || []).map(function(i) {
      var p = FIXED_PRODUCTS.find(function(x) { return x.id === i.productId; });
      return '<tr><td>' + (p ? p.name : i.productId) + '</td><td style="text-align:right;">' + i.qty + ' ชิ้น</td></tr>';
    }).join('');
  } catch(e) { return '<tr><td colspan="2">-</td></tr>'; }
}

function showBillModal(id, type, contentHtml) {
  var modal = document.getElementById('billDetailModal');
  if (!modal) {
    modal = document.createElement('div');
    modal.id = 'billDetailModal';
    modal.className = 'modal';
    document.body.appendChild(modal);
  }
  modal.innerHTML = '<div class="modal-content" style="max-width:520px;max-height:90vh;overflow-y:auto;"><div class="modal-header"><h3>' + type + ' - ' + id + '</h3><span class="close" onclick="closeModal(\'billDetailModal\')">&times;</span></div><div class="modal-body">' + contentHtml + '</div><div class="modal-footer"><button class="btn-secondary" onclick="closeModal(\'billDetailModal\')">ปิด</button></div></div>';
  openModal('billDetailModal');
}

function renderFilteredMoves(tableId, moves, from, to) {
  var movBody = document.getElementById(tableId);
  if (moves.length === 0) {
    movBody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:40px;">ไม่มีรายการในช่วงนี้</td></tr>';
    return;
  }
  var w = 0, c = 0;
  var rows = moves.map(function(m) {
    var goldG = parseFloat(m.goldG) || 0;
    var price = parseFloat(m.price) || 0;
    var gIn = m.dir === 'IN' ? goldG : 0;
    var gOut = m.dir === 'OUT' ? goldG : 0;
    var pIn = m.dir === 'IN' ? price : 0;
    var pOut = m.dir === 'OUT' ? price : 0;
    w += gIn - gOut;
    c += pIn - pOut;
    return '<tr>' +
      '<td>' + m.id + '</td>' +
      '<td><span class="status-badge">' + m.type + '</span></td>' +
      '<td style="color:#4caf50;">' + (gIn > 0 ? formatWeight(gIn) : '-') + '</td>' +
      '<td style="color:#f44336;">' + (gOut > 0 ? formatWeight(gOut) : '-') + '</td>' +
      '<td style="font-weight:bold;">' + formatWeight(w) + '</td>' +
      '<td style="color:#4caf50;">' + (pIn > 0 ? formatNumber(pIn) : '-') + '</td>' +
      '<td style="color:#f44336;">' + (pOut > 0 ? formatNumber(pOut) : '-') + '</td>' +
      '<td style="font-weight:bold;">' + formatNumber(Math.round(c)) + '</td>' +
      '<td><button class="btn-action" onclick="viewBillDetail(\'' + m.id + '\',\'' + m.type + '\')">📋</button></td>' +
      '</tr>';
  }).join('');
  movBody.innerHTML = rows;
}

async function openTransferModal() {
  document.getElementById('transferOldProducts').innerHTML = '';
  addTransferProduct();
  await loadStockInModal();
  openModal('transferModal');
}

async function loadStockInModal() {
  try {
    var rows = await dbSelect('stock_balances', {
      select: 'product_id,qty',
      filters: { gold_type: 'eq.OLD' },
      useCache: false
    });
    var balMap = {};
    (rows || []).forEach(function(r) { balMap[r.product_id] = parseFloat(r.qty) || 0; });
    var products = ['G01','G02','G03','G04','G05','G06','G07'];
    var html = products.map(function(pid) {
      var qty = balMap[pid] || 0;
      if (qty <= 0) return null;
      var p = FIXED_PRODUCTS.find(function(x) { return x.id === pid; });
      return '<tr><td>' + pid + '</td><td>' + (p ? p.name : 'Unknown') + '</td><td>' + qty + '</td></tr>';
    }).filter(function(r) { return r !== null; }).join('');
    document.getElementById('stockSummaryInModal').innerHTML = html || '<tr><td colspan="3" style="text-align: center; padding: 20px;">No OLD stock</td></tr>';
  } catch(e) { console.error('Error loading stock in modal:', e); }
}

function addTransferProduct() {
  var container = document.getElementById('transferOldProducts');
  var row = document.createElement('div');
  row.className = 'product-row';
  row.style.cssText = 'display: flex; gap: 10px; margin-bottom: 10px; align-items: center;';
  row.innerHTML = '<select class="form-input" style="flex: 1;">' +
    FIXED_PRODUCTS.map(function(p) { return '<option value="' + p.id + '">' + p.name + '</option>'; }).join('') +
    '</select><input type="number" class="form-input" placeholder="Quantity" min="1" style="width: 150px;">' +
    '<button class="btn-danger" onclick="this.parentElement.remove()" style="padding: 8px 15px;">Remove</button>';
  container.appendChild(row);
}

async function confirmTransfer() {
  try {
    var rows = document.querySelectorAll('#transferOldProducts .product-row');
    var items = [];
    for (var i = 0; i < rows.length; i++) {
      var qty = parseInt(rows[i].querySelector('input').value);
      if (!qty || qty <= 0) { alert('กรุณากรอกจำนวนให้ถูกต้อง'); return; }
      items.push({ productId: rows[i].querySelector('select').value, qty: qty });
    }
    if (items.length === 0) { alert('กรุณาเพิ่มสินค้าอย่างน้อย 1 รายการ'); return; }
    if (!confirm('ยืนยันการโอนทองเก่าไปทองใหม่ ' + items.length + ' รายการ?')) return;
    showLoading();
    var result = await dbRpc('transfer_old_to_new_tx', { p_items: mergeItems(items) });
    hideLoading();
    if (result && result.success) {
      showToast('✅ ' + result.message);
      closeModal('transferModal');
      await loadStockOld();
    } else {
      alert('❌ ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch(e) { alert('❌ ' + e.message); hideLoading(); }
}

function openStockOutModal() {
  document.getElementById('stockOutProducts').innerHTML = '';
  document.getElementById('stockOutNote').value = '';
  addStockOutProduct();
  openModal('stockOutModal');
}

function addStockOutProduct() {
  var container = document.getElementById('stockOutProducts');
  var row = document.createElement('div');
  row.className = 'product-row';
  row.style.cssText = 'display: flex; gap: 10px; margin-bottom: 10px; align-items: center;';
  row.innerHTML = '<select class="form-input" style="flex: 1;">' +
    FIXED_PRODUCTS.map(function(p) { return '<option value="' + p.id + '">' + p.name + '</option>'; }).join('') +
    '</select><input type="number" class="form-input" placeholder="Quantity" min="1" style="width: 150px;">' +
    '<button class="btn-danger" onclick="this.parentElement.remove()" style="padding: 8px 15px;">Remove</button>';
  container.appendChild(row);
}

async function confirmStockOut() {
  try {
    var rows = document.querySelectorAll('#stockOutProducts .product-row');
    var items = [];
    for (var i = 0; i < rows.length; i++) {
      var qty = parseInt(rows[i].querySelector('input').value);
      if (!qty || qty <= 0) { alert('กรุณากรอกจำนวนให้ถูกต้อง'); return; }
      items.push({ productId: rows[i].querySelector('select').value, qty: qty });
    }
    if (items.length === 0) { alert('กรุณาเพิ่มสินค้าอย่างน้อย 1 รายการ'); return; }
    var note = document.getElementById('stockOutNote').value.trim();
    if (!confirm('ยืนยันการ Stock Out (OLD) ' + items.length + ' รายการ?')) return;
    showLoading();
    var result = await dbRpc('stock_out_old_tx', { p_items: mergeItems(items), p_note: note });
    hideLoading();
    if (result && result.success) {
      showToast('✅ ' + result.message);
      closeModal('stockOutModal');
      await loadStockOld();
    } else {
      alert('❌ ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch(e) { alert('❌ ' + e.message); hideLoading(); }
}
