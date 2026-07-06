function getTodayLocalStr() {
  var d = new Date();
  var offset = 7 * 60;
  var local = new Date(d.getTime() + offset * 60000);
  return local.toISOString().split('T')[0];
}

function isManager() {
  return currentUser && (currentUser.role === 'Manager' || currentUser.role === 'Admin');
}

function getGoldWeight(productId) {
  var weights = { 'G01': 150, 'G02': 75, 'G03': 30, 'G04': 15, 'G05': 7.5, 'G06': 3.75, 'G07': 1 };
  return weights[productId] || 0;
}

function mergeItems(items) {
  var map = {};
  items.forEach(function(item) {
    if (map[item.productId]) {
      map[item.productId].qty += item.qty;
    } else {
      map[item.productId] = { productId: item.productId, qty: item.qty };
    }
  });
  return Object.keys(map).map(function(k) { return map[k]; });
}

function formatNumber(num) {
  var n = typeof num === 'string' ? parseFloat(num.replace(/,/g, '')) : num;
  if (typeof n !== 'number' || isNaN(n)) n = 0;
  return new Intl.NumberFormat('en-US').format(Math.round(n));
}

function formatCurrency(amount, currency) {
  var n = typeof amount === 'string' ? parseFloat(amount.replace(/,/g, '')) : amount;
  if (isNaN(n)) n = 0;
  var cur = String(currency || '').trim().toUpperCase();
  if (cur === 'THB' || cur === 'USD') {
    return new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n);
  }
  return new Intl.NumberFormat('en-US').format(Math.round(n));
}

function formatWeight(num) {
  return new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(num);
}

function parseSheetDate(dateValue) {
  if (!dateValue) return null;
  
  try {
    var result = null;

    if (dateValue instanceof Date) {
      result = dateValue;
    } else if (typeof dateValue === 'number') {
      result = new Date((dateValue - 25569) * 86400 * 1000);
    } else if (typeof dateValue === 'string') {
      if (dateValue.includes('/')) {
        var parts = dateValue.split(' ');
        var dateParts = parts[0].split('/');
        var day = parseInt(dateParts[0]);
        var month = parseInt(dateParts[1]) - 1;
        var year = parseInt(dateParts[2]);
        
        if (parts.length > 1 && parts[1] && parts[1].includes(':')) {
          var timeParts = parts[1].split(':');
          var hour = parseInt(timeParts[0]) || 0;
          var minute = parseInt(timeParts[1]) || 0;
          var second = parseInt(timeParts[2]) || 0;
          result = new Date(year, month, day, hour, minute, second);
        } else {
          result = new Date(year, month, day);
        }
      } else {
        var isoMatch = dateValue.match(/^(\d{4})-(\d{2})-(\d{2})/);
        if (isoMatch) {
          var tMatch = dateValue.match(/(\d{2}):(\d{2}):?(\d{2})?/);
          if (tMatch) {
            result = new Date(parseInt(isoMatch[1]), parseInt(isoMatch[2]) - 1, parseInt(isoMatch[3]), parseInt(tMatch[1]) || 0, parseInt(tMatch[2]) || 0, parseInt(tMatch[3]) || 0);
          } else {
            result = new Date(parseInt(isoMatch[1]), parseInt(isoMatch[2]) - 1, parseInt(isoMatch[3]));
          }
        } else {
          result = new Date(dateValue);
        }
      }
    } else {
      result = new Date(dateValue);
    }

    if (result && !isNaN(result.getTime())) return result;
    return null;
  } catch (error) {
    return null;
  }
}

function formatDateOnly(dateInput) {
  if (!dateInput) return '-';
  
  try {
    let d;
    
    if (typeof dateInput === 'string') {
      const parts = dateInput.split(' ')[0].split('/');
      if (parts.length === 3) {
        const day = parseInt(parts[0]);
        const month = parseInt(parts[1]);
        const year = parseInt(parts[2]);
        d = new Date(year, month - 1, day);
      } else {
        d = new Date(dateInput);
      }
    } else if (typeof dateInput === 'number') {
      d = new Date((dateInput - 25569) * 86400 * 1000);
    } else if (dateInput instanceof Date) {
      d = dateInput;
    } else {
      return '-';
    }
    
    if (isNaN(d.getTime())) return '-';
    
    const day = String(d.getDate()).padStart(2, '0');
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const year = d.getFullYear();
    return `${day}/${month}/${year}`;
  } catch (error) {
    return '-';
  }
}

function formatDateTime(dateInput) {
  if (!dateInput) return '-';
  
  try {
    let d;
    
    if (typeof dateInput === 'string') {
      if (dateInput.includes('/') && dateInput.includes(':')) {
        const [datePart, timePart] = dateInput.split(' ');
        const dateParts = datePart.split('/');
        const timeParts = timePart.split(':');
        
        const day = parseInt(dateParts[0]);
        const month = parseInt(dateParts[1]);
        const year = parseInt(dateParts[2]);
        const hour = parseInt(timeParts[0]);
        const minute = parseInt(timeParts[1]);
        const second = timeParts[2] ? parseInt(timeParts[2]) : 0;
        
        d = new Date(year, month - 1, day, hour, minute, second);
      } else {
        d = new Date(dateInput);
      }
    } else if (typeof dateInput === 'number') {
      d = new Date((dateInput - 25569) * 86400 * 1000);
    } else if (dateInput instanceof Date) {
      d = dateInput;
    } else {
      return '-';
    }
    
    if (isNaN(d.getTime())) return '-';
    
    const day = String(d.getDate()).padStart(2, '0');
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const year = d.getFullYear();
    const hour = String(d.getHours()).padStart(2, '0');
    const minute = String(d.getMinutes()).padStart(2, '0');
    return `${day}/${month}/${year} ${hour}:${minute}`;
  } catch (error) {
    return '-';
  }
}

const formatDate = formatDateTime;

function subtractItems(allJson, focJson) {
  try {
    var all = typeof allJson === 'string' ? JSON.parse(allJson) : allJson;
    var foc = typeof focJson === 'string' ? JSON.parse(focJson) : focJson;
    if (!Array.isArray(all)) return allJson;
    if (!Array.isArray(foc) || foc.length === 0) return JSON.stringify(all);
    var focMap = {};
    foc.forEach(function(f) { focMap[f.productId] = (focMap[f.productId] || 0) + f.qty; });
    var result = [];
    all.forEach(function(item) {
      var remain = item.qty - (focMap[item.productId] || 0);
      if (remain > 0) result.push({ productId: item.productId, qty: remain });
      if (focMap[item.productId]) focMap[item.productId] = Math.max(0, focMap[item.productId] - item.qty);
    });
    return JSON.stringify(result);
  } catch(e) { return allJson; }
}

function formatItemsForTable(itemsJson) {
  try {
    const items = JSON.parse(itemsJson);
    return items.map(item => {
      const product = FIXED_PRODUCTS.find(p => p.id === item.productId);
      return `${product ? product.name : item.productId}: ${item.qty} unit`;
    }).join('<br>');
  } catch (error) {
    return itemsJson;
  }
}

function formatItemsForDisplay(itemsJson) {
  try {
    const items = JSON.parse(itemsJson);
    return items.map(item => {
      const product = FIXED_PRODUCTS.find(p => p.id === item.productId);
      return `• ${product ? product.name : item.productId} × ${item.qty}`;
    }).join('\n');
  } catch (error) {
    return itemsJson;
  }
}

function calculatePremiumFromItems(itemsJson) {
  try {
    const items = JSON.parse(itemsJson);
    let totalPremium = 0;
    items.forEach(item => {
      if (PREMIUM_PRODUCTS.includes(item.productId)) {
        totalPremium += PREMIUM_PER_PIECE * item.qty;
      }
    });
    return totalPremium;
  } catch {
    return 0;
  }
}

function filterTodayData(data, dateColumnIndex, createdByIndex) {
  const today = new Date();
  const todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  
  return data.filter(row => {
    const dateValue = row[dateColumnIndex];
    const createdBy = row[createdByIndex];
    
    let rowDate;
    if (dateValue instanceof Date) {
      rowDate = dateValue;
    } else if (typeof dateValue === 'string') {
      if (dateValue.includes('/')) {
        const parts = dateValue.split(' ');
        const dateParts = parts[0].split('/');
        const day = parseInt(dateParts[0]);
        const month = parseInt(dateParts[1]) - 1;
        const year = parseInt(dateParts[2]);
        rowDate = new Date(year, month, day);
      } else {
        var isoMatch = dateValue.match(/^(\d{4})-(\d{2})-(\d{2})/);
        if (isoMatch) {
          rowDate = new Date(parseInt(isoMatch[1]), parseInt(isoMatch[2]) - 1, parseInt(isoMatch[3]));
        } else {
          rowDate = new Date(dateValue);
        }
      }
    } else {
      rowDate = new Date(dateValue);
    }
    
    const rowDateStart = new Date(rowDate.getFullYear(), rowDate.getMonth(), rowDate.getDate());
    const isToday = rowDateStart.getTime() === todayStart.getTime();
    
    if (isManager()) {
      return isToday;
    } else if (currentUser.role === 'User') {
      return isToday && createdBy === currentUser.nickname;
    }
    return isToday;
  });
}

var _isSubmitting = false;
var _submitTimeout = null;

function showLoading() {
  document.getElementById('loading').classList.add('active');
  if (_isSubmitting && !_submitTimeout) {
    _submitTimeout = setTimeout(function() { _isSubmitting = false; hideLoading(); }, 30000);
  }
  var activeModal = document.querySelector('.modal.active');
  if (activeModal) {
    activeModal.querySelectorAll('.modal-footer button').forEach(function(btn) {
      btn.disabled = true;
    });
  }
}

function hideLoading() {
  document.getElementById('loading').classList.remove('active');
  _isSubmitting = false;
  if (_submitTimeout) { clearTimeout(_submitTimeout); _submitTimeout = null; }
  var activeModal = document.querySelector('.modal.active');
  if (activeModal) {
    activeModal.querySelectorAll('.modal-footer button').forEach(function(btn) {
      btn.disabled = false;
    });
  }
}

function startSubmit() {
  if (_isSubmitting) return false;
  _isSubmitting = true;
  showLoading();
  _submitTimeout = setTimeout(function() { _isSubmitting = false; }, 30000);
  return true;
}

function endSubmit() {
  _isSubmitting = false;
  if (_submitTimeout) { clearTimeout(_submitTimeout); _submitTimeout = null; }
  hideLoading();
}

function openModal(modalId) {
  var modal = document.getElementById(modalId);
  modal.classList.add('active');
  modal.querySelectorAll('.modal-footer button').forEach(function(btn) {
    btn.disabled = false;
  });
}

var _shiftCompleted = false;
var _closeWorkLocked = false;

function closeModal(modalId) {
  if (modalId === 'openShiftModal' && !_shiftCompleted) return;
  if (modalId === 'closeWorkModal' && _closeWorkLocked) return;
  document.getElementById(modalId).classList.remove('active');
}

function roundTo1000(num) {
  return Math.ceil(num / 1000) * 1000;
}

// ทอนเงินให้ลูกค้า (LAK): <1000 → 0, ≥1000 → ปัดหลักพันใกล้สุด
// 22500 → 23000, 22490 → 22000, 999 → 0, 1500 → 2000
// สำหรับ THB/USD ให้แปลง×rate→LAK ก่อนเรียก
function roundChangeLak(lak) {
  var n = parseFloat(lak) || 0;
  if (n < 1000) return 0;
  return Math.round(n / 1000) * 1000;
}

// DD/MM/YYYY HH:MM
function formatTimeShort(dateStr) {
  if (!dateStr) return '-';
  var d = new Date(dateStr);
  if (isNaN(d.getTime())) return '-';
  var hh = String(d.getHours()).padStart(2, '0');
  var mm = String(d.getMinutes()).padStart(2, '0');
  var dd = String(d.getDate()).padStart(2, '0');
  var mo = String(d.getMonth() + 1).padStart(2, '0');
  return dd + '/' + mo + '/' + d.getFullYear() + ' ' + hh + ':' + mm;
}

function calculateSellPrice(productId, sell1Baht) {
  var price = 0;
  switch(productId) {
    case 'G01': price = sell1Baht * 10; break;
    case 'G02': price = sell1Baht * 5; break;
    case 'G03': price = sell1Baht * 2; break;
    case 'G04': price = sell1Baht; break;
    case 'G05': price = (sell1Baht / 2); break;
    case 'G06': price = (sell1Baht / 4); break;
    case 'G07': return Math.ceil(((sell1Baht / 15) + 120000) / 1000) * 1000;
  }
  return Math.round(price / 1000) * 1000;
}

function calculateBuybackPrice(productId, sell1Baht) {
  const buyback1B = sell1Baht - 530000;
  
  let price = 0;
  switch(productId) {
    case 'G01': price = buyback1B * 10; break;
    case 'G02': price = buyback1B * 5; break;
    case 'G03': price = buyback1B * 2; break;
    case 'G04': price = buyback1B; break;
    case 'G05': price = buyback1B / 2; break;
    case 'G06': price = buyback1B / 4; break;
    case 'G07': return Math.floor((buyback1B / 15) / 1000) * 1000;
  }
  return Math.round(price / 1000) * 1000;
}

function filterByDateRange(data, dateColumnIndex, createdByIndex, dateFrom, dateTo) {
  var from = null;
  var to = null;

  if (dateFrom) {
    var fParts = dateFrom.split('-');
    from = new Date(parseInt(fParts[0]), parseInt(fParts[1]) - 1, parseInt(fParts[2]), 0, 0, 0, 0);
  }
  if (dateTo) {
    var tParts = dateTo.split('-');
    to = new Date(parseInt(tParts[0]), parseInt(tParts[1]) - 1, parseInt(tParts[2]), 23, 59, 59, 999);
  }
  
  return data.filter(row => {
    const dateValue = row[dateColumnIndex];
    const createdBy = row[createdByIndex];
    
    let rowDate;
    if (dateValue instanceof Date) {
      rowDate = dateValue;
    } else if (typeof dateValue === 'string') {
      if (dateValue.includes('/')) {
        const parts = dateValue.split(' ');
        const dateParts = parts[0].split('/');
        const day = parseInt(dateParts[0]);
        const month = parseInt(dateParts[1]) - 1;
        const year = parseInt(dateParts[2]);
        if (parts.length > 1 && parts[1]) {
          const timeParts = parts[1].split(':');
          rowDate = new Date(year, month, day, parseInt(timeParts[0]) || 0, parseInt(timeParts[1]) || 0, parseInt(timeParts[2]) || 0);
        } else {
          rowDate = new Date(year, month, day);
        }
      } else {
        var isoMatch = dateValue.match(/^(\d{4})-(\d{2})-(\d{2})/);
        if (isoMatch) {
          var tMatch = dateValue.match(/(\d{2}):(\d{2}):?(\d{2})?/);
          if (tMatch) {
            rowDate = new Date(parseInt(isoMatch[1]), parseInt(isoMatch[2]) - 1, parseInt(isoMatch[3]), parseInt(tMatch[1]) || 0, parseInt(tMatch[2]) || 0, parseInt(tMatch[3]) || 0);
          } else {
            rowDate = new Date(parseInt(isoMatch[1]), parseInt(isoMatch[2]) - 1, parseInt(isoMatch[3]));
          }
        } else {
          rowDate = new Date(dateValue);
        }
      }
    } else {
      rowDate = new Date(dateValue);
    }
    
    let inRange = true;
    if (from) {
      inRange = inRange && rowDate >= from;
    }
    if (to) {
      inRange = inRange && rowDate <= to;
    }
    
    if (isManager()) {
      return inRange;
    } else if (currentUser.role === 'User') {
      return inRange && createdBy === currentUser.nickname;
    }
    return inRange;
  });
}

function getTodayDateString() {
  const today = new Date();
  const year = today.getFullYear();
  const month = String(today.getMonth() + 1).padStart(2, '0');
  const day = String(today.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

async function viewTransactionDetail(type, jsonData) {
  var row = JSON.parse(decodeURIComponent(jsonData));

  var txId = '';
  row.forEach(function(item) { if (item[0] === 'Transaction ID') txId = item[1]; });

  var html = '<div style="padding:20px;">';
  html += '<h3 style="color:var(--gold-primary);margin-bottom:15px;">' + type.toUpperCase() + ' Detail</h3>';
  html += '<table style="width:100%;border-collapse:collapse;">';
  row.forEach(function(item) {
    if (item[0] === 'Customer Paid' || item[0] === 'Change') return;
    html += '<tr style="border-bottom:1px solid var(--border-color);">';
    html += '<td style="padding:8px 12px;color:var(--text-secondary);white-space:nowrap;">' + item[0] + '</td>';
    html += '<td style="padding:8px 12px;font-weight:600;">' + item[1] + '</td>';
    html += '</tr>';
  });
  html += '</table>';

  if (txId) {
    html += '<div id="paymentDetailSection" style="margin-top:15px;padding:12px;background:rgba(212,175,55,0.08);border-radius:8px;border:1px solid rgba(212,175,55,0.2);">';
    html += '<div style="font-size:12px;color:var(--gold-primary);margin-bottom:8px;font-weight:bold;">💳 รายละเอียดการชำระเงิน</div>';
    html += '<div style="text-align:center;padding:10px;"><div style="display:inline-block;width:18px;height:18px;border:2px solid var(--border-color);border-top:2px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></div>';
    html += '</div>';
  }

  var status = '';
  row.forEach(function(item) { if (item[0] === 'Status') status = item[1]; });
  if (status === 'COMPLETED' || status === 'PAID') {
    html += '<div style="text-align:center;margin-top:20px;"><button class="btn-primary" onclick="printBill(\'' + encodeURIComponent(JSON.stringify(row)) + '\',\'' + type + '\')" style="background:#d4af37;border-color:#d4af37;">🖨️ Print Bill</button></div>';
  }

  html += '</div>';

  var modal = document.getElementById('viewDetailModal');
  if (!modal) {
    modal = document.createElement('div');
    modal.id = 'viewDetailModal';
    modal.className = 'modal';
    modal.innerHTML = '<div class="modal-content" style="max-width:500px;"><div id="viewDetailContent"></div><div style="text-align:right;padding:0 20px 20px;"><button class="btn-secondary" onclick="closeModal(\'viewDetailModal\')">Close</button></div></div>';
    document.body.appendChild(modal);
  }
  document.getElementById('viewDetailContent').innerHTML = html;
  openModal('viewDetailModal');

  if (txId) {
    try {
      var payments = await dbSelect('transaction_payments', {
        select: 'amount,currency,method,note,bank:banks!bank_id(name)',
        filters: { tx_id: 'eq.' + txId },
        order: 'paid_at.asc',
        useCache: false
      });

      var section = document.getElementById('paymentDetailSection');
      if (!section) return;

      if (!payments || payments.length === 0) {
        section.innerHTML = '<div style="font-size:12px;color:var(--gold-primary);margin-bottom:8px;font-weight:bold;">💳 รายละเอียดการชำระเงิน</div>' +
          '<p style="font-size:12px;color:var(--text-secondary);">ไม่พบข้อมูลการชำระเงิน</p>';
        return;
      }

      var payHtml = '<div style="font-size:12px;color:var(--gold-primary);margin-bottom:8px;font-weight:bold;">💳 รายละเอียดการชำระเงิน</div>';
      payments.forEach(function(p) {
        var amt = parseFloat(p.amount) || 0;
        var cur = p.currency || 'LAK';
        var method = String(p.method || '').toUpperCase();
        var bank = (p.bank && p.bank.name) ? p.bank.name : '';
        var note = String(p.note || '');
        var isChange = note.toLowerCase().indexOf('change') !== -1;
        var isFee = note.toLowerCase().indexOf('fee') !== -1;

        var icon, label;
        if (isChange) {
          icon = '💰';
          label = 'เงินทอน';
        } else if (isFee) {
          icon = '🏦';
          label = 'ค่าธรรมเนียม' + (bank ? ' ' + bank : '');
        } else if (method !== 'CASH' && bank) {
          icon = '🏦';
          label = bank + ' (' + cur + ')';
        } else {
          icon = '💵';
          label = 'เงินสด (' + cur + ')';
        }

        var color = isChange ? '#ff9800' : isFee ? '#f44336' : '#4caf50';
        var sign = amt < 0 ? '' : '+';
        payHtml += '<div style="display:flex;justify-content:space-between;align-items:center;padding:6px 0;border-bottom:1px solid rgba(255,255,255,0.05);">';
        payHtml += '<span style="font-size:13px;">' + icon + ' ' + label + '</span>';
        payHtml += '<span style="font-size:13px;font-weight:bold;color:' + color + ';">' + sign + formatCurrency(amt, cur) + ' ' + cur + '</span>';
        payHtml += '</div>';
      });

      section.innerHTML = payHtml;
    } catch(e) {
      var section = document.getElementById('paymentDetailSection');
      if (section) section.innerHTML = '<div style="font-size:12px;color:var(--gold-primary);margin-bottom:8px;font-weight:bold;">💳 รายละเอียดการชำระเงิน</div><p style="font-size:12px;color:#f44336;">โหลดข้อมูลไม่สำเร็จ</p>';
    }
  }
}

async function deleteTransactionSupabase(id, type) {
  if (!confirm('ยืนยันลบรายการ ' + id + ' ?')) return;
  try {
    showLoading();
    var result = await dbRpc('delete_tx', { p_tx_id: id });
    hideLoading();
    if (result && result.success) {
      showToast('✅ ลบสำเร็จ');
      if (typeof loadSells === 'function') loadSells();
      if (typeof loadTradeins === 'function') loadTradeins();
      if (typeof loadExchanges === 'function') loadExchanges();
      if (typeof loadWithdraws === 'function') loadWithdraws();
      if (typeof loadBuybacks === 'function') loadBuybacks();
      if (typeof loadHistorySell === 'function') loadHistorySell();
    } else {
      alert('❌ ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch(e) {
    hideLoading();
    alert('❌ ' + e.message);
  }
}

function printBill(encodedData, type) {
  var data = JSON.parse(decodeURIComponent(encodedData));
  var txId = '', phone = '', total = '', date = '', sale = '';
  var items = [];
  data.forEach(function(item) {
    if (item[0] === 'Transaction ID') txId = item[1];
    if (item[0] === 'Phone') phone = item[1];
    if (item[0] === 'Total') total = item[1];
    if (item[0] === 'Date') date = item[1];
    if (item[0] === 'Sale') sale = item[1];
  });

  var detailRows = '';
  data.forEach(function(item) {
    if (item[0] === 'Transaction ID' || item[0] === 'Status') return;
    detailRows += '<tr><td style="padding:6px 10px;color:#666;font-size:12px;border-bottom:1px solid #eee;">' + item[0] + '</td><td style="padding:6px 10px;font-weight:600;font-size:12px;text-align:right;border-bottom:1px solid #eee;">' + item[1] + '</td></tr>';
  });

  var printWin = window.open('', '_blank', 'width=400,height=600');
  printWin.document.write('<!DOCTYPE html><html><head><title>Bill ' + txId + '</title><style>' +
    '@page { size: 148mm 210mm; margin: 8mm; }' +
    'body { font-family: "Segoe UI", Arial, sans-serif; margin: 0; padding: 15px; color: #333; max-width: 380px; margin: 0 auto; }' +
    '.header { text-align: center; border-bottom: 3px double #d4af37; padding-bottom: 12px; margin-bottom: 12px; }' +
    '.logo { font-size: 22px; font-weight: 700; color: #d4af37; letter-spacing: 2px; }' +
    '.sub { font-size: 11px; color: #888; margin-top: 4px; }' +
    '.bill-type { display: inline-block; background: #d4af37; color: #fff; padding: 4px 16px; border-radius: 20px; font-size: 13px; font-weight: 700; margin: 10px 0; letter-spacing: 1px; }' +
    '.info { display: flex; justify-content: space-between; font-size: 11px; color: #666; margin-bottom: 10px; padding: 0 5px; }' +
    'table { width: 100%; border-collapse: collapse; }' +
    '.total-row { background: #fffbf0; }' +
    '.total-row td { padding: 10px !important; font-size: 16px !important; font-weight: 700 !important; color: #d4af37 !important; border-top: 2px solid #d4af37 !important; border-bottom: none !important; }' +
    '.footer { text-align: center; margin-top: 15px; padding-top: 12px; border-top: 1px dashed #ccc; font-size: 10px; color: #999; }' +
    '.ref { font-size: 10px; color: #aaa; margin-top: 8px; text-align: center; }' +
    '</style></head><body>' +
    '<div class="header">' +
    '<div class="logo">KPV GOLD</div>' +
    '<div class="sub">ร้านทอง KPV</div>' +
    '</div>' +
    '<div style="text-align:center;"><span class="bill-type">' + type.toUpperCase() + '</span></div>' +
    '<div class="info"><span>Ref: ' + txId + '</span><span>' + date + '</span></div>' +
    '<div class="info"><span>Phone: ' + phone + '</span><span>Sale: ' + sale + '</span></div>' +
    '<table>' + detailRows + '</table>' +
    '<table><tr class="total-row"><td style="text-align:right;">Total</td><td style="text-align:right;">' + total + '</td></tr></table>' +
    '<div class="ref">Thank you for your purchase</div>' +
    '<div class="footer">Printed: ' + new Date().toLocaleString('th-TH') + '</div>' +
    '</body></html>');
  printWin.document.close();
  setTimeout(function() { printWin.print(); }, 300);
}

var _deletedDateFrom = null;
var _deletedDateTo = null;

async function loadDeletedList() {
  try {
    var tbody = document.getElementById('deletedListTable');
    tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';

    if (!_deletedDateFrom || !_deletedDateTo) {
      var td = getTodayDateString();
      _deletedDateFrom = td;
      _deletedDateTo = td;
    }
    document.getElementById('deletedDateFrom').value = _deletedDateFrom;
    document.getElementById('deletedDateTo').value = _deletedDateTo;

    var rows = await dbSelect('audit_logs', {
      select: 'created_at,table_name,ref_id,action,payload,user:users!user_id(nickname)',
      filters: {
        action: 'eq.DELETE',
        table_name: 'eq.transactions',
        and: '(created_at.gte.' + _deletedDateFrom + 'T00:00:00,created_at.lte.' + _deletedDateTo + 'T23:59:59)'
      },
      order: 'created_at.desc',
      useCache: false
    });

    if (!rows || rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;padding:40px;">No deleted records</td></tr>';
      return;
    }

    tbody.innerHTML = rows.map(function(r) {
      var p = r.payload || {};
      var type = String(p.type || '');
      var typeColors = { 'SELL': '#4caf50', 'TRADEIN': '#2196f3', 'EXCHANGE': '#ff9800', 'SWITCH': '#ff9800', 'FREE_EXCHANGE': '#ff9800', 'BUYBACK': '#9c27b0', 'WITHDRAW': '#f44336' };
      var tColor = typeColors[type] || '#888';

      var detail = '';
      if (type) {
        var parts = [];
        if (p.phone) parts.push('<b>Phone:</b> ' + p.phone);
        if (p.bill_id) parts.push('<b>Bill ID:</b> ' + p.bill_id);
        if (p.total !== undefined && p.total !== null) parts.push('<b>Total:</b> ' + formatNumber(p.total) + ' LAK');
        if (p.paid !== undefined && p.paid !== null && parseFloat(p.paid) > 0) parts.push('<b>Paid:</b> ' + formatNumber(p.paid) + ' ' + (p.currency || 'LAK'));
        if (p.premium !== undefined && p.premium !== null && parseFloat(p.premium) > 0) parts.push('<b>Premium:</b> ' + formatNumber(p.premium));
        if (p.ex_fee !== undefined && p.ex_fee !== null && parseFloat(p.ex_fee) > 0) parts.push('<b>Ex Fee:</b> ' + formatNumber(p.ex_fee));
        if (p.fee !== undefined && p.fee !== null && parseFloat(p.fee) > 0) parts.push('<b>Fee:</b> ' + formatNumber(p.fee));
        if (p.diff_amount !== undefined && p.diff_amount !== null && parseFloat(p.diff_amount) !== 0) parts.push('<b>Diff:</b> ' + formatNumber(p.diff_amount));
        if (p.status) parts.push('<b>Status:</b> ' + p.status);
        if (p.note) parts.push('<b>Note:</b> ' + p.note);
        detail = parts.join('<br>');
      } else {
        try { detail = JSON.stringify(p).substring(0, 200); } catch(e) { detail = '-'; }
      }

      var nickname = (r.user && r.user.nickname) ? r.user.nickname : '-';

      return '<tr>' +
        '<td style="font-size:11px;white-space:nowrap;">' + formatDateTime(r.created_at) + '</td>' +
        '<td style="font-weight:bold;">' + (r.ref_id || '') + '</td>' +
        '<td><span style="background:' + tColor + ';color:#fff;padding:2px 8px;border-radius:4px;font-size:11px;">' + (type || '-') + '</span></td>' +
        '<td>' + (r.table_name || '') + '</td>' +
        '<td style="font-size:12px;line-height:1.6;">' + detail + '</td>' +
        '<td>' + nickname + '</td>' +
        '</tr>';
    }).join('');
  } catch(e) {
    var tbody = document.getElementById('deletedListTable');
    if (tbody) tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;padding:40px;color:#f44336;">Error: ' + e.message + '</td></tr>';
  }
}

function filterDeletedList() {
  _deletedDateFrom = document.getElementById('deletedDateFrom').value;
  _deletedDateTo = document.getElementById('deletedDateTo').value;
  if (_deletedDateFrom && !_deletedDateTo) { _deletedDateTo = _deletedDateFrom; document.getElementById('deletedDateTo').value = _deletedDateTo; }
  if (!_deletedDateFrom && _deletedDateTo) { _deletedDateFrom = _deletedDateTo; document.getElementById('deletedDateFrom').value = _deletedDateFrom; }
  if (_deletedDateFrom && _deletedDateTo) loadDeletedList();
}

function resetDeletedDateFilter() {
  var td = getTodayDateString();
  _deletedDateFrom = td;
  _deletedDateTo = td;
  loadDeletedList();
}