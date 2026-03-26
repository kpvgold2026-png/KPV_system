async function safeFetch(range) {
  try {
    return await fetchSheetData(range);
  } catch(e) {
    return [];
  }
}

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
    loadStockOldSummary();
    loadStockOldMoves();
  } else {
    loadStockOldFiltered();
  }
}

async function loadStockOldSummary() {
  try {
    var stockData = await safeFetch('Stock_Old!A:D');
    var carry = {}, qtyIn = {}, qtyOut = {};
    FIXED_PRODUCTS.forEach(function(p) { carry[p.id] = 0; qtyIn[p.id] = 0; qtyOut[p.id] = 0; });
    if (stockData.length > 1) {
      var lastRow = stockData[stockData.length - 1];
      try { carry = JSON.parse(lastRow[1] || '{}'); } catch(e) {}
      try { qtyIn = JSON.parse(lastRow[2] || '{}'); } catch(e) {}
      try { qtyOut = JSON.parse(lastRow[3] || '{}'); } catch(e) {}
    }
    renderStockOldSummary(carry, qtyIn, qtyOut);
  } catch(e) { console.error('Error loading stock old summary:', e); }
}

async function loadStockOldMoves() {
  try {
    var moveResult = await callAppsScript('GET_STOCK_MOVES', { sheet: 'StockMove_Old' });
    var prevW = moveResult.data ? moveResult.data.prevW || 0 : 0;
    var prevC = moveResult.data ? moveResult.data.prevC || 0 : 0;
    var moves = moveResult.data ? moveResult.data.moves || [] : [];
    renderStockOldMovements(moves, prevW, prevC, true);
  } catch(e) { console.error('Error loading stock old moves:', e); }
}

async function loadStockOldFiltered() {
  try {
    var stockData = await safeFetch('Stock_Old!A:D');
    var from = new Date(stockOldDateFrom); from.setHours(0,0,0,0);
    var to = new Date(stockOldDateTo); to.setHours(23,59,59,999);
    var carry = {}, qtyIn = {}, qtyOut = {};
    FIXED_PRODUCTS.forEach(function(p) { carry[p.id] = 0; qtyIn[p.id] = 0; qtyOut[p.id] = 0; });
    var foundCarry = false;
    for (var r = 1; r < stockData.length; r++) {
      var rd = new Date(stockData[r][0]);
      if (isNaN(rd.getTime())) continue;
      rd.setHours(0,0,0,0);
      if (rd >= from && rd <= to) {
        if (!foundCarry) {
          try { carry = JSON.parse(stockData[r][1] || '{}'); } catch(e) {}
          foundCarry = true;
        }
        var ri = {}, ro = {};
        try { ri = JSON.parse(stockData[r][2] || '{}'); } catch(e) {}
        try { ro = JSON.parse(stockData[r][3] || '{}'); } catch(e) {}
        FIXED_PRODUCTS.forEach(function(p) { qtyIn[p.id] += (ri[p.id] || 0); qtyOut[p.id] += (ro[p.id] || 0); });
      }
    }
    renderStockOldSummary(carry, qtyIn, qtyOut);

    var moveResult = await callAppsScript('GET_STOCK_MOVES_RANGE', { sheet: 'StockMove_Old', dateFrom: stockOldDateFrom, dateTo: stockOldDateTo });
    var moves = moveResult.data ? moveResult.data.moves || [] : [];
    renderFilteredMoves('stockOldMovementTable', moves, stockOldDateFrom, stockOldDateTo);
    document.getElementById('stockOldGoldG').textContent = '-';
    document.getElementById('stockOldCostValue').textContent = '-';
  } catch(e) { console.error('Error loading stock old filtered:', e); }
}

function renderStockOldSummary(carry, qtyIn, qtyOut) {
  document.getElementById('stockOldSummaryTable').innerHTML = FIXED_PRODUCTS.map(function(p) {
    var c = carry[p.id] || 0;
    var i = qtyIn[p.id] || 0;
    var o = qtyOut[p.id] || 0;
    return '<tr><td>' + p.id + '</td><td>' + p.name + '</td><td>' + c + '</td>' +
      '<td style="color:#4caf50;">' + i + '</td>' +
      '<td style="color:#f44336;">' + o + '</td>' +
      '<td style="font-weight:bold;">' + (c + i - o) + '</td></tr>';
  }).join('');
}

function renderStockOldMovements(moves, prevW, prevC, showRunning) {
  var todayMovements = moves.map(function(m) {
    var gIn = m.dir === 'IN' ? m.goldG : 0;
    var gOut = m.dir === 'OUT' ? m.goldG : 0;
    var pIn = m.dir === 'IN' ? m.price : 0;
    var pOut = m.dir === 'OUT' ? m.price : 0;
    return { id: m.id, type: m.type, goldIn: gIn, goldOut: gOut, priceIn: pIn, priceOut: pOut };
  });

  var w = prevW, c = prevC;
  todayMovements.forEach(function(m) {
    w += m.goldIn - m.goldOut;
    c += m.priceIn - m.priceOut;
    m.w = w; m.c = c;
  });

  var latestW = todayMovements.length > 0 ? todayMovements[todayMovements.length - 1].w : prevW;
  var latestC = todayMovements.length > 0 ? todayMovements[todayMovements.length - 1].c : prevC;

  document.getElementById('stockOldGoldG').textContent = formatWeight(latestW) + ' g';
  document.getElementById('stockOldCostValue').textContent = formatNumber(Math.round(latestC)) + ' LAK';
  window._stockOldLatest = { goldG: latestW, cost: latestC };

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
  } else {
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
    f.addEventListener('change', function() { stockOldDateFrom = this.value; if (stockOldDateFrom && !stockOldDateTo) { stockOldDateTo = stockOldDateFrom; t.value = stockOldDateTo; } if (stockOldDateFrom && stockOldDateTo) loadStockOld(); });
    t.addEventListener('change', function() { stockOldDateTo = this.value; if (stockOldDateTo && !stockOldDateFrom) { stockOldDateFrom = stockOldDateTo; f.value = stockOldDateFrom; } if (stockOldDateFrom && stockOldDateTo) loadStockOld(); });
  }
});

async function viewBillDetail(id, type) {
  try {
    showLoading();
    var sheetRange = null;

    if (type === 'BUYBACK') sheetRange = 'Buybacks!A:L';
    else if (type === 'TRADE-IN') sheetRange = 'Tradeins!A:N';
    else if (type === 'EXCHANGE') sheetRange = 'Exchanges!A:N';
    else if (type === 'SWITCH') sheetRange = 'Switches!A:N';
    else if (type === 'FREE-EX') sheetRange = 'FreeExchanges!A:J';
    else if (type === 'SELL') sheetRange = 'Sells!A:L';
    else if (type === 'WITHDRAW') sheetRange = 'Withdraws!A:J';

    var fetches = [
      fetchSheetData('StockMove_Old!A:K'),
      fetchSheetData('StockMove_New!A:K')
    ];
    if (sheetRange) fetches.push(fetchSheetData(sheetRange));
    var results = await Promise.all(fetches);

    var moveRow = null;
    for (var si = 0; si < 2; si++) {
      var sData = results[si];
      if (sData && sData.length > 1) {
        for (var mi = sData.length - 1; mi >= 1; mi--) {
          if (String(sData[mi][1] || '') === id) {
            moveRow = {
              id: sData[mi][1],
              type: sData[mi][2],
              items: sData[mi][3],
              goldG: parseFloat(sData[mi][4]) || 0,
              dir: String(sData[mi][5] || ''),
              price: parseFloat(sData[mi][6]) || 0,
              user: sData[mi][7],
              wacG: parseFloat(sData[mi][8]) || 0,
              wacB: parseFloat(sData[mi][9]) || 0
            };
            break;
          }
        }
        if (moveRow) break;
      }
    }

    var txData = results.length > 2 ? results[2] : [];
    var row = txData.length > 1 ? txData.slice(1).find(function(r) { return r[0] === id; }) : null;
    
    var stockNote = '';
    try {
      var stockData = await fetchSheetData('Stock!A:H');
      if (stockData && stockData.length > 1) {
        for (var sn = stockData.length - 1; sn >= 1; sn--) {
          if (String(stockData[sn][3] || '') === id) {
            stockNote = String(stockData[sn][5] || '');
            break;
          }
        }
      }
    } catch(e) {}
    
    hideLoading();

    var fmtItems = function(json) {
      try {
        return JSON.parse(json).map(function(i) {
          var p = FIXED_PRODUCTS.find(function(x) { return x.id === i.productId; });
          return '<tr><td>' + (p ? p.name : i.productId) + '</td><td style="text-align:right;">' + i.qty + ' ชิ้น</td></tr>';
        }).join('');
      } catch(e) { return '<tr><td colspan="2">' + json + '</td></tr>'; }
    };

    var html = '<div style="margin-bottom:15px;"><span style="font-size:12px;color:var(--text-secondary);">Transaction ID</span><br><span style="font-size:18px;font-weight:bold;color:var(--gold-primary);">' + id + '</span></div>';
    html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:15px;">';
    html += '<div><span style="color:var(--text-secondary);font-size:12px;">ประเภท</span><br><span class="status-badge">' + type + '</span></div>';

    if (row) {
      if (type === 'BUYBACK') {
        html += '<div><span style="color:var(--text-secondary);font-size:12px;">สถานะ</span><br><span class="status-badge">' + (row[10] || '-') + '</span></div></div>';
        html += '<div style="margin-bottom:15px;"><table class="data-table" style="width:100%;"><thead><tr><th>สินค้า</th><th>จำนวน</th></tr></thead><tbody>' + fmtItems(row[2]) + '</tbody></table></div>';
        html += '<div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;">';
        html += '<div class="stat-card" style="padding:10px;"><div style="color:var(--text-secondary);font-size:11px;">ราคา</div><div style="font-weight:bold;">' + formatNumber(row[3]) + '</div></div>';
        html += '<div class="stat-card" style="padding:10px;"><div style="color:var(--text-secondary);font-size:11px;">ค่าธรรมเนียม</div><div style="font-weight:bold;">' + formatNumber(row[5]) + '</div></div>';
        html += '<div class="stat-card" style="padding:10px;"><div style="color:var(--text-secondary);font-size:11px;">รวม</div><div style="font-weight:bold;color:var(--gold-primary);">' + formatNumber(row[6]) + '</div></div></div>';
      } else if (type === 'TRADE-IN' || type === 'EXCHANGE' || type === 'SWITCH') {
        html += '<div><span style="color:var(--text-secondary);font-size:12px;">สถานะ</span><br><span class="status-badge">' + (row[12] || '-') + '</span></div></div>';
        html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:15px;">';
        html += '<div><span style="color:#ff9800;font-size:12px;">🥇 ทองเก่า</span><table class="data-table" style="width:100%;margin-top:5px;"><tbody>' + fmtItems(row[2]) + '</tbody></table></div>';
        html += '<div><span style="color:#2196f3;font-size:12px;">💎 ทองใหม่</span><table class="data-table" style="width:100%;margin-top:5px;"><tbody>' + fmtItems(row[3]) + '</tbody></table></div></div>';
        html += '<div class="stat-card" style="padding:10px;text-align:center;"><div style="color:var(--text-secondary);font-size:11px;">ยอดรวม</div><div style="font-weight:bold;font-size:18px;color:var(--gold-primary);">' + formatNumber(row[6]) + ' LAK</div></div>';
      } else if (type === 'FREE-EX') {
        html += '<div><span style="color:var(--text-secondary);font-size:12px;">สถานะ</span><br><span class="status-badge">' + (row[8] || '-') + '</span></div></div>';
        html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:15px;">';
        html += '<div><span style="color:#ff9800;font-size:12px;">🥇 ทองเก่า</span><table class="data-table" style="width:100%;margin-top:5px;"><tbody>' + fmtItems(row[2]) + '</tbody></table></div>';
        html += '<div><span style="color:#2196f3;font-size:12px;">💎 ทองใหม่</span><table class="data-table" style="width:100%;margin-top:5px;"><tbody>' + fmtItems(row[3]) + '</tbody></table></div></div>';
        html += '<div class="stat-card" style="padding:10px;text-align:center;"><div style="color:var(--text-secondary);font-size:11px;">Premium</div><div style="font-weight:bold;font-size:18px;color:var(--gold-primary);">' + formatNumber(row[4]) + ' LAK</div></div>';
      } else if (type === 'SELL') {
        html += '<div><span style="color:var(--text-secondary);font-size:12px;">สถานะ</span><br><span class="status-badge">' + (row[10] || '-') + '</span></div></div>';
        html += '<div style="margin-bottom:15px;"><table class="data-table" style="width:100%;"><thead><tr><th>สินค้า</th><th>จำนวน</th></tr></thead><tbody>' + fmtItems(row[2]) + '</tbody></table></div>';
        html += '<div class="stat-card" style="padding:10px;text-align:center;"><div style="color:var(--text-secondary);font-size:11px;">ยอดรวม</div><div style="font-weight:bold;font-size:18px;color:var(--gold-primary);">' + formatNumber(row[3]) + ' LAK</div></div>';
      } else if (type === 'WITHDRAW') {
        html += '<div><span style="color:var(--text-secondary);font-size:12px;">สถานะ</span><br><span class="status-badge">' + (row[7] || '-') + '</span></div></div>';
        html += '<div style="margin-bottom:15px;"><table class="data-table" style="width:100%;"><thead><tr><th>สินค้า</th><th>จำนวน</th></tr></thead><tbody>' + fmtItems(row[2]) + '</tbody></table></div>';
        html += '<div class="stat-card" style="padding:10px;text-align:center;"><div style="color:var(--text-secondary);font-size:11px;">ยอดรวม</div><div style="font-weight:bold;font-size:18px;color:var(--gold-primary);">' + formatNumber(row[4]) + ' LAK</div></div>';
      }
    } else if (moveRow) {
      html += '<div><span style="color:var(--text-secondary);font-size:12px;">Direction</span><br><span class="status-badge">' + (moveRow.dir || '') + '</span></div></div>';
      html += '<div style="margin-bottom:15px;"><table class="data-table" style="width:100%;"><thead><tr><th>สินค้า</th><th>จำนวน</th></tr></thead><tbody>' + fmtItems(moveRow.items) + '</tbody></table></div>';
      html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;">';
      html += '<div class="stat-card" style="padding:10px;"><div style="color:var(--text-secondary);font-size:11px;">น้ำหนัก</div><div style="font-weight:bold;">' + formatWeight(moveRow.goldG || 0) + ' g</div></div>';
      html += '<div class="stat-card" style="padding:10px;"><div style="color:var(--text-secondary);font-size:11px;">มูลค่า</div><div style="font-weight:bold;color:var(--gold-primary);">' + formatNumber(moveRow.price) + ' LAK</div></div></div>';
    } else {
      html += '<div></div></div><p style="text-align:center;color:var(--text-secondary);">ไม่พบข้อมูลเพิ่มเติม</p>';
    }

    if (moveRow) {
      var wG = parseFloat(moveRow.wacG) || 0;
      var wB = parseFloat(moveRow.wacB) || 0;
      if (wG > 0 || wB > 0) {
        html += '<div style="margin-top:15px;padding:12px;background:rgba(212,175,55,0.08);border-radius:8px;border:1px solid rgba(212,175,55,0.2);">';
        html += '<div style="font-size:12px;color:var(--gold-primary);margin-bottom:8px;font-weight:bold;">📊 WAC ณ เวลาทำรายการ</div>';
        html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;">';
        html += '<div><span style="color:var(--text-secondary);font-size:11px;">WAC/g</span><br><span style="font-weight:bold;">' + formatNumber(wG) + ' LAK</span></div>';
        html += '<div><span style="color:var(--text-secondary);font-size:11px;">WAC/บาท</span><br><span style="font-weight:bold;">' + formatNumber(wB) + ' LAK</span></div>';
        html += '</div></div>';
      }
    }

    if (stockNote) {
      html += '<div style="margin-top:15px;padding:12px;background:rgba(255,255,255,0.05);border-radius:8px;border:1px solid var(--border-color);">';
      html += '<div style="font-size:12px;color:var(--text-secondary);margin-bottom:4px;">📝 Note</div>';
      html += '<div style="font-size:13px;">' + stockNote + '</div>';
      html += '</div>';
    }

    showBillModal(id, type, html);
  } catch(e) {
    hideLoading();
    showBillModal('Error', '', '<p style="color:#f44336;">' + e.message + '</p>');
  }
}

function showBillModal(id, type, contentHtml) {
  var modal = document.getElementById('billDetailModal');
  if (!modal) {
    modal = document.createElement('div');
    modal.id = 'billDetailModal';
    modal.className = 'modal';
    document.body.appendChild(modal);
  }
  modal.innerHTML = '<div class="modal-content" style="max-width:520px;"><div class="modal-header"><h3>' + type + ' - ' + id + '</h3><span class="close" onclick="closeModal(\'billDetailModal\')">&times;</span></div><div class="modal-body" style="max-height:70vh;overflow-y:auto;">' + contentHtml + '</div><div class="modal-footer"><button class="btn-secondary" onclick="closeModal(\'billDetailModal\')">ปิด</button></div></div>';
  openModal('billDetailModal');
}

function renderFilteredMoves(tableId, moves, from, to) {
  var movBody = document.getElementById(tableId);
  if (moves.length === 0) {
    movBody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:40px;">ไม่มีรายการในช่วง ' + from + ' ถึง ' + to + '</td></tr>';
    return;
  }
  var rows = '';
  var w = 0, c = 0;
  moves.forEach(function(m) {
    var gIn = m.dir === 'IN' ? m.goldG : 0;
    var gOut = m.dir === 'OUT' ? m.goldG : 0;
    var pIn = m.dir === 'IN' ? m.price : 0;
    var pOut = m.dir === 'OUT' ? m.price : 0;
    w += gIn - gOut;
    c += pIn - pOut;
    rows += '<tr>' +
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
  });
  rows += '<tr style="background:rgba(212,175,55,0.1);font-weight:bold;">' +
    '<td colspan="4" style="text-align:right;">รวมทั้งหมด</td>' +
    '<td>' + formatWeight(w) + '</td><td colspan="2"></td>' +
    '<td>' + formatNumber(Math.round(c)) + '</td><td></td></tr>';
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
    var data = await fetchSheetData('_database!A10:G10');
    if (data.length === 0) {
      document.getElementById('stockSummaryInModal').innerHTML = '<tr><td colspan="3" style="text-align: center; padding: 20px;">No stock data</td></tr>';
      return;
    }
    var oldGoldRow = data[0];
    var products = ['G01','G02','G03','G04','G05','G06','G07'];
    var rows = products.map(function(pid, idx) {
      var qty = parseFloat(oldGoldRow[idx]) || 0;
      if (qty <= 0) return null;
      var p = FIXED_PRODUCTS.find(function(x) { return x.id === pid; });
      return '<tr><td>' + pid + '</td><td>' + (p ? p.name : 'Unknown') + '</td><td>' + qty + '</td></tr>';
    }).filter(function(r) { return r !== null; }).join('');
    document.getElementById('stockSummaryInModal').innerHTML = rows || '<tr><td colspan="3" style="text-align: center; padding: 20px;">No OLD stock</td></tr>';
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
    var result = await callAppsScript('TRANSFER_OLD_TO_NEW', { items: JSON.stringify(mergeItems(items)) });
    if (result.success) {
      showToast('✅ ' + result.message);
      closeModal('transferModal');
      await loadStockOld();
    } else { alert('❌ ' + result.message); }
    hideLoading();
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
    var result = await callAppsScript('STOCK_OUT_OLD', { items: JSON.stringify(mergeItems(items)), note: note });
    if (result.success) {
      showToast('✅ ' + result.message);
      closeModal('stockOutModal');
      await loadStockOld();
    } else { alert('❌ ' + result.message); }
    hideLoading();
  } catch(e) { alert('❌ ' + e.message); hideLoading(); }
}
