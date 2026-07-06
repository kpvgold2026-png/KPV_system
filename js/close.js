var currentCloseId = null;
var _closePollingInterval = null;

async function checkAndResumePendingClose() {
  if (!currentUser || isManager()) return;
  try {
    var today = getTodayLocalStr();
    var rows = await dbSelect('closes', {
      select: 'id,status,date,cash_summary,bank_summary,gold_summary,total_tx,total_amount',
      filters: { user_id: 'eq.' + currentUser.id, 'and': '(date.gte.' + today + 'T00:00:00+07:00,date.lte.' + today + 'T23:59:59+07:00)' },
      useCache: false
    });

    var myPending = (rows || []).find(function(r) { return r.status === 'PENDING'; });
    var myApproved = (rows || []).find(function(r) { return r.status === 'APPROVED'; });

    if (!myPending && !myApproved) return;

    if (myPending) {
      currentCloseId = myPending.id;
      await openCloseWorkModal(true);
      _wireResumePendingUI(myPending.id);
      startClosePolling();
    } else if (myApproved) {
      currentCloseId = myApproved.id;
      _renderClosedSummary(myApproved);
      _wireApprovedUI();
      _closeWorkLocked = true;
      openModal('closeWorkModal');
      var modal = document.getElementById('closeWorkModal');
      if (modal) modal.onclick = function(e) { e.stopImmediatePropagation(); };
    }
  } catch(e) {
    console.error('Error checking pending close:', e);
  }
}

function _renderClosedSummary(closeRow) {
  var cash = closeRow.cash_summary || {};
  var bank = closeRow.bank_summary || {};
  var gold = closeRow.gold_summary || {};
  var newOut = gold.newOut || {};
  var oldIn = gold.oldIn || {};

  var productNames = { 'G01': '10 บาท', 'G02': '5 บาท', 'G03': '2 บาท', 'G04': '1 บาท', 'G05': '2 สลึง', 'G06': '1 สลึง', 'G07': '1 กรัม' };
  var pids = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06', 'G07'];

  var moneyKeys = [
    { key: 'Cash', label: '💵 Cash', data: cash },
    { key: 'BCEL', label: '🏦 BCEL Bank', data: bank.BCEL || {} },
    { key: 'LDB', label: '🏦 LDB Bank', data: bank.LDB || {} },
    { key: 'Other', label: '🏦 Bank อื่นๆ', data: bank.Other || {} }
  ];
  var moneyTableRows = moneyKeys.map(function(m) {
    var d = m.data || {};
    return '<tr><td style="padding:6px 10px;font-weight:600;">' + m.label + '</td>' +
      '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(parseFloat(d.LAK) || 0)) + '</td>' +
      '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(parseFloat(d.THB) || 0)) + '</td>' +
      '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(parseFloat(d.USD) || 0)) + '</td></tr>';
  }).join('');

  document.getElementById('closeWorkSummary').innerHTML =
    '<div style="text-align:center;margin-bottom:15px;">' +
    '<p style="font-size:18px;color:var(--gold-primary);">สรุปยอดประจำวัน</p>' +
    '<p style="color:var(--text-secondary);">' + currentUser.nickname + ' — ' + getTodayLocalStr() + '</p>' +
    '<p style="color:#4caf50;font-weight:bold;margin-top:8px;">✅ สถานะ: Manager ยืนยันแล้ว (' + closeRow.id + ')</p>' +
    '</div>' +

    '<div class="stat-card" style="text-align:center;margin-bottom:15px;">' +
    '<h3 style="color:var(--gold-primary);margin-bottom:8px;">ยอดรวมทั้งวัน</h3>' +
    '<p style="font-size:24px;font-weight:bold;margin:4px 0;">' + formatNumber(Math.round(parseFloat(closeRow.total_amount) || 0)) + ' <span style="font-size:12px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);">' + (closeRow.total_tx || 0) + ' บิล</p></div>' +

    '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:15px;">' +
    '<div class="stat-card" style="padding:15px;">' +
    '<h3 style="color:#4caf50;margin-bottom:10px;font-size:14px;">▶ ทองใหม่ที่จ่ายออก</h3>' +
    '<table style="width:100%;border-collapse:collapse;">' +
    pids.map(function(pid) { return '<tr><td style="padding:4px 10px;">' + productNames[pid] + '</td><td style="padding:4px 10px;text-align:center;font-weight:bold;">' + (newOut[pid] || 0) + '</td></tr>'; }).join('') +
    '</table></div>' +
    '<div class="stat-card" style="padding:15px;">' +
    '<h3 style="color:#ff9800;margin-bottom:10px;font-size:14px;">◀ ทองเก่าที่ได้รับ</h3>' +
    '<table style="width:100%;border-collapse:collapse;">' +
    pids.map(function(pid) { return '<tr><td style="padding:4px 10px;">' + productNames[pid] + '</td><td style="padding:4px 10px;text-align:center;font-weight:bold;">' + (oldIn[pid] || 0) + '</td></tr>'; }).join('') +
    '</table></div></div>' +

    '<div class="stat-card" style="padding:15px;margin-bottom:15px;">' +
    '<h3 style="color:var(--gold-primary);margin-bottom:4px;font-size:14px;">💰 เงินที่ถือทั้งหมด (ส่งเข้าร้านแล้ว)</h3>' +
    '<p style="font-size:11px;color:var(--text-secondary);margin:0 0 10px 0;">รวมยอดยกมาจากวันก่อน (ถ้ามี)</p>' +
    '<table style="width:100%;border-collapse:collapse;">' +
    '<tr style="border-bottom:2px solid var(--border-color);"><th style="padding:6px 10px;text-align:left;color:var(--text-secondary);font-size:12px;">ประเภท</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">LAK</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">THB</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">USD</th></tr>' +
    moneyTableRows + '</table></div>';
}

function _wireApprovedUI() {
  var cancelBtn = document.getElementById('closeWorkCancelBtn');
  if (cancelBtn) cancelBtn.style.display = 'none';
  var refreshCloseBtn = document.getElementById('closeRefreshBtn');
  if (refreshCloseBtn) refreshCloseBtn.style.display = 'none';
  var submitBtn = document.getElementById('closeWorkSubmitBtn');
  if (submitBtn) {
    submitBtn.style.background = '#4caf50';
    submitBtn.style.color = '#fff';
    submitBtn.textContent = '✅ ตกลง';
    submitBtn.disabled = false;
    submitBtn.onclick = function() {
      _closeWorkLocked = false;
      var modal = document.getElementById('closeWorkModal');
      if (modal) modal.onclick = null;
      closeModal('closeWorkModal');
      logout();
    };
  }
}

function _wireResumePendingUI(closeId) {
  var cancelBtn = document.getElementById('closeWorkCancelBtn');
  if (cancelBtn) {
    cancelBtn.style.display = 'inline-block';
    cancelBtn.textContent = '❌ ยกเลิกปิดกะ';
    cancelBtn.style.background = '#f44336';
    cancelBtn.style.color = '#fff';
    cancelBtn.onclick = function() { cancelPendingClose(closeId); };
  }
  var submitBtn = document.getElementById('closeWorkSubmitBtn');
  if (submitBtn) {
    submitBtn.onclick = null;
    submitBtn.style.background = '#d4af37';
    submitBtn.style.color = '#000';
    submitBtn.textContent = '⏳ รอ Manager ยืนยัน...';
    submitBtn.disabled = true;
  }
  var refreshCloseBtn = document.getElementById('closeRefreshBtn');
  if (!refreshCloseBtn) {
    refreshCloseBtn = document.createElement('button');
    refreshCloseBtn.id = 'closeRefreshBtn';
    refreshCloseBtn.className = 'btn-secondary';
    refreshCloseBtn.style.cssText = 'margin-left:10px;padding:8px 16px;font-size:14px;';
    refreshCloseBtn.textContent = '↻ รีเฟรช';
    if (submitBtn && submitBtn.parentNode) submitBtn.parentNode.insertBefore(refreshCloseBtn, submitBtn.nextSibling);
  }
  refreshCloseBtn.style.display = 'inline-block';
  refreshCloseBtn.onclick = async function() {
    refreshCloseBtn.textContent = '↻ กำลังเช็ค...';
    refreshCloseBtn.disabled = true;
    try {
      var rows2 = await dbSelect('closes', {
        select: 'id,status,cash_summary,bank_summary,gold_summary,total_tx,total_amount',
        filters: { id: 'eq.' + closeId },
        useCache: false
      });
      if (rows2 && rows2.length > 0) {
        var status = rows2[0].status;
        if (status === 'APPROVED') {
          if (_closePollingInterval) { clearInterval(_closePollingInterval); _closePollingInterval = null; }
          _renderClosedSummary(rows2[0]);
          _wireApprovedUI();
        } else if (status === 'REJECTED') {
          if (_closePollingInterval) { clearInterval(_closePollingInterval); _closePollingInterval = null; }
          if (cancelBtn) cancelBtn.style.display = 'none';
          refreshCloseBtn.style.display = 'none';
          if (submitBtn) {
            submitBtn.style.background = '#f44336';
            submitBtn.style.color = '#fff';
            submitBtn.textContent = '❌ ปฏิเสธ - กดเพื่อรับทราบ';
            submitBtn.disabled = false;
            submitBtn.onclick = function() {
              _closeWorkLocked = false;
              closeModal('closeWorkModal');
            };
          }
        } else {
          showToast('⏳ ยังไม่ได้รับการอนุมัติ');
        }
      }
    } catch(e) {}
    refreshCloseBtn.textContent = '↻ รีเฟรช';
    refreshCloseBtn.disabled = false;
  };
}

async function cancelPendingClose(closeId) {
  if (!confirm('ยกเลิกการปิดกะ?')) return;
  try {
    showLoading();
    // ยกเลิกผ่าน RPC — server ลบเฉพาะ close ของตัวเองที่ยัง PENDING
    // (กัน race: Manager อาจ approve ไปแล้วระหว่างรอ polling)
    var result = await dbRpc('cancel_pending_close', { p_close_id: String(closeId) });
    hideLoading();
    if (result && result.success) {
      showToast('✅ ยกเลิกแล้ว');
      closeModal('closeWorkModal');
      _closeWorkLocked = false;
      if (_closePollingInterval) { clearInterval(_closePollingInterval); _closePollingInterval = null; }
    } else {
      alert('❌ ' + (result && result.message ? result.message : 'ยกเลิกไม่สำเร็จ'));
      var refreshBtn = document.getElementById('closeRefreshBtn');
      if (refreshBtn && refreshBtn.onclick) refreshBtn.onclick();
    }
  } catch(e) {
    hideLoading();
    alert('❌ ' + e.message);
  }
}

async function openCloseWorkModal(isResume) {
  try {
    showLoading();
    var today = getTodayLocalStr();

    if (!isResume) {
      var existing = await dbSelect('closes', {
        select: 'id,status,date',
        filters: { user_id: 'eq.' + currentUser.id, 'and': '(date.gte.' + today + 'T00:00:00+07:00,date.lte.' + today + 'T23:59:59+07:00)', 'status': 'in.(PENDING,APPROVED)' },
        useCache: false
      });
      if (existing && existing.length > 0) {
        hideLoading();
        alert('❌ คุณได้ปิดงานวันนี้แล้ว (' + existing[0].id + ' - ' + existing[0].status + ')');
        return;
      }
    }

    var data = await dbRpc('get_close_report', { p_date: today });

    var txs = data && data.txs ? data.txs : [];
    var cashbook = data && data.cashbook ? data.cashbook : [];
    var goldReceived = data && data.gold_received ? data.gold_received : [];

    var sellMoney = 0, sellGoldG = 0, sellCount = 0;
    var bbMoney = 0, bbGoldG = 0, bbCount = 0;
    var newGoldOut = { G01: 0, G02: 0, G03: 0, G04: 0, G05: 0, G06: 0, G07: 0 };
    var oldGoldReceived = {};

    txs.forEach(function(t) {
      var amt = parseFloat(t.total) || 0;
      var items = t.items || [];
      if (t.type === 'SELL' || t.type === 'TRADEIN' || t.type === 'EXCHANGE') {
        sellMoney += amt;
        sellCount++;
        items.forEach(function(it) {
          if (it.role === 'NEW') {
            if (newGoldOut[it.productId] !== undefined) newGoldOut[it.productId] += (parseFloat(it.qty) || 0);
            sellGoldG += (getGoldWeight(it.productId) || 0) * (parseFloat(it.qty) || 0);
          }
        });
      } else if (t.type === 'BUYBACK') {
        bbMoney += amt;
        bbCount++;
        items.forEach(function(it) {
          bbGoldG += (getGoldWeight(it.productId) || 0) * (parseFloat(it.qty) || 0);
        });
      }
    });

    goldReceived.forEach(function(g) {
      var pid = g.product_id;
      var qty = parseFloat(g.qty) || 0;
      if (pid && qty > 0) oldGoldReceived[pid] = (oldGoldReceived[pid] || 0) + qty;
    });

    var moneyGrid = {
      Cash: { LAK: 0, THB: 0, USD: 0 },
      BCEL: { LAK: 0, THB: 0, USD: 0 },
      LDB: { LAK: 0, THB: 0, USD: 0 },
      Other: { LAK: 0, THB: 0, USD: 0 }
    };

    // ดึง cashbook ที่ join กับ bank.name เพื่อแยก BCEL/LDB/Other ได้ถูกต้อง
    var cashbookWithBank = null;
    try {
      cashbookWithBank = await dbRpc('get_close_cashbook', { p_user_id: currentUser.id, p_date: today });
    } catch(e) { console.warn('get_close_cashbook not available — falling back to cashbook from get_close_report:', e); }

    var rowsToUse = (cashbookWithBank && Array.isArray(cashbookWithBank)) ? cashbookWithBank : cashbook;
    rowsToUse.forEach(function(c) {
      var amt = parseFloat(c.amount) || 0;
      var cur = c.currency;
      var method = c.method || 'CASH';
      var bankName = (c.bank_name || '').toUpperCase();
      var key;
      if (method === 'CASH') key = 'Cash';
      else if (bankName.indexOf('BCEL') === 0) key = 'BCEL';
      else if (bankName.indexOf('LDB') === 0) key = 'LDB';
      else key = 'Other';
      if (moneyGrid[key] && moneyGrid[key][cur] !== undefined) {
        moneyGrid[key][cur] += amt;
      }
    });

    var productNames = { 'G01': '10 บาท', 'G02': '5 บาท', 'G03': '2 บาท', 'G04': '1 บาท', 'G05': '2 สลึง', 'G06': '1 สลึง', 'G07': '1 กรัม' };
    var pids = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06', 'G07'];

    var moneyTableRows = ['Cash', 'BCEL', 'LDB', 'Other'].map(function(key) {
      return '<tr><td style="padding:6px 10px;font-weight:bold;">' + key + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[key].LAK)) + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[key].THB)) + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[key].USD)) + '</td></tr>';
    }).join('');

    document.getElementById('closeWorkSummary').innerHTML =
      '<div style="text-align:center;margin-bottom:20px;">' +
      '<p style="font-size:18px;color:var(--gold-primary);">สรุปยอดประจำวัน</p>' +
      '<p style="color:var(--text-secondary);">' + currentUser.nickname + ' — ' + today + '</p>' +
      '</div>' +

      '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:15px;">' +
      '<div class="stat-card" style="text-align:center;">' +
      '<h3 style="color:#4caf50;margin-bottom:8px;">💰 ยอดทองที่ขาย</h3>' +
      '<p style="font-size:20px;font-weight:bold;margin:4px 0;">' + formatNumber(Math.round(sellMoney)) + ' <span style="font-size:12px;">LAK</span></p>' +
      '<p style="font-size:14px;color:var(--text-secondary);margin:2px 0;">' + sellGoldG.toFixed(2) + ' g</p>' +
      '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">' + sellCount + ' บิล</p>' +
      '</div>' +
      '<div class="stat-card" style="text-align:center;">' +
      '<h3 style="color:#ff9800;margin-bottom:8px;">🔄 ยอดทองที่ซื้อคืน</h3>' +
      '<p style="font-size:20px;font-weight:bold;margin:4px 0;">' + formatNumber(Math.round(bbMoney)) + ' <span style="font-size:12px;">LAK</span></p>' +
      '<p style="font-size:14px;color:var(--text-secondary);margin:2px 0;">' + bbGoldG.toFixed(2) + ' g</p>' +
      '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">' + bbCount + ' บิล</p>' +
      '</div>' +
      '</div>' +

      '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:15px;">' +
      '<div class="stat-card" style="padding:15px;">' +
      '<h3 style="color:#4caf50;margin-bottom:10px;font-size:14px;">▶ ทองใหม่ที่จ่ายออก</h3>' +
      '<table style="width:100%;border-collapse:collapse;"><tr style="border-bottom:1px solid var(--border-color);"><th style="padding:5px 10px;text-align:left;font-size:12px;">Product</th><th style="padding:5px 10px;text-align:center;font-size:12px;">Unit</th></tr>' +
      pids.map(function(pid) { return '<tr><td style="padding:4px 10px;">' + productNames[pid] + '</td><td style="padding:4px 10px;text-align:center;font-weight:bold;">' + newGoldOut[pid] + '</td></tr>'; }).join('') +
      '</table></div>' +
      '<div class="stat-card" style="padding:15px;">' +
      '<h3 style="color:#ff9800;margin-bottom:10px;font-size:14px;">◀ ทองเก่าที่ได้รับ</h3>' +
      '<table style="width:100%;border-collapse:collapse;"><tr style="border-bottom:1px solid var(--border-color);"><th style="padding:5px 10px;text-align:left;font-size:12px;">Product</th><th style="padding:5px 10px;text-align:center;font-size:12px;">Unit</th></tr>' +
      pids.map(function(pid) { return '<tr><td style="padding:4px 10px;">' + productNames[pid] + '</td><td style="padding:4px 10px;text-align:center;font-weight:bold;">' + (oldGoldReceived[pid] || 0) + '</td></tr>'; }).join('') +
      '</table></div>' +
      '</div>' +

      '<div class="stat-card" style="padding:15px;margin-bottom:15px;">' +
      // ยอดจาก get_close_cashbook = เงินที่ถือทั้งหมดในกระเป๋า (รวมยอดยกมาจากวันก่อน)
      // ให้ตรงกับยอดที่ถูกกวาดเข้าร้านจริงตอน Manager อนุมัติ
      '<h3 style="color:var(--gold-primary);margin-bottom:4px;font-size:14px;">💰 เงินที่ถือทั้งหมด (ที่จะส่งเข้าร้าน)</h3>' +
      '<p style="font-size:11px;color:var(--text-secondary);margin:0 0 10px 0;">รวมยอดยกมาจากวันก่อน (ถ้ามี) — ยอดนี้คือเงินที่จะถูกโอนเข้าร้านเมื่อ Manager อนุมัติ</p>' +
      '<table style="width:100%;border-collapse:collapse;">' +
      '<tr style="border-bottom:2px solid var(--border-color);"><th style="padding:6px 10px;text-align:left;font-size:12px;">ประเภท</th><th style="padding:6px 10px;text-align:right;font-size:12px;">LAK</th><th style="padding:6px 10px;text-align:right;font-size:12px;">THB</th><th style="padding:6px 10px;text-align:right;font-size:12px;">USD</th></tr>' +
      moneyTableRows +
      '</table></div>';

    window.currentCloseSummary = {
      date: today,
      cash_summary: moneyGrid.Cash,
      bank_summary: { BCEL: moneyGrid.BCEL, LDB: moneyGrid.LDB, Other: moneyGrid.Other },
      gold_summary: { newOut: newGoldOut, oldIn: oldGoldReceived },
      total_tx: sellCount + bbCount,
      total_amount: sellMoney + bbMoney
    };

    hideLoading();
    openModal('closeWorkModal');
  } catch (error) {
    console.error('Error opening close work modal:', error);
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

async function submitCloseWork() {
  if (_isSubmitting) return;
  if (!window.currentCloseSummary) return;
  try {
    _isSubmitting = true;
    showLoading();
    var s = window.currentCloseSummary;
    var result = await dbRpc('submit_close_report', {
      p_date: s.date,
      p_cash_summary: s.cash_summary,
      p_bank_summary: s.bank_summary,
      p_gold_summary: s.gold_summary,
      p_total_tx: s.total_tx,
      p_total_amount: s.total_amount,
      p_note: ''
    });
    hideLoading();

    if (result && result.success) {
      showToast('✅ ส่ง Close สำเร็จ! รอ Manager อนุมัติ');
      _closeWorkLocked = true;
      var closeId = result.id || '';
      currentCloseId = closeId;

      var cancelBtn = document.getElementById('closeWorkCancelBtn');
      if (cancelBtn) {
        cancelBtn.style.display = 'inline-block';
        cancelBtn.textContent = '❌ ยกเลิกปิดกะ';
        cancelBtn.style.background = '#f44336';
        cancelBtn.style.color = '#fff';
        cancelBtn.onclick = function() { cancelPendingClose(closeId); };
      }

      var submitBtn = document.getElementById('closeWorkSubmitBtn');
      if (submitBtn) {
        submitBtn.onclick = null;
        submitBtn.style.background = '#d4af37';
        submitBtn.style.color = '#000';
        submitBtn.textContent = '⏳ รอ Manager ยืนยัน...';
        submitBtn.disabled = true;
      }

      var refreshCloseBtn = document.getElementById('closeRefreshBtn');
      if (!refreshCloseBtn) {
        refreshCloseBtn = document.createElement('button');
        refreshCloseBtn.id = 'closeRefreshBtn';
        refreshCloseBtn.className = 'btn-secondary';
        refreshCloseBtn.style.cssText = 'margin-left:10px;padding:8px 16px;font-size:14px;';
        refreshCloseBtn.textContent = '↻ รีเฟรช';
        if (submitBtn && submitBtn.parentNode) submitBtn.parentNode.insertBefore(refreshCloseBtn, submitBtn.nextSibling);
      }
      refreshCloseBtn.style.display = 'inline-block';
      refreshCloseBtn.onclick = async function() {
        refreshCloseBtn.textContent = '↻ กำลังเช็ค...';
        refreshCloseBtn.disabled = true;
        try {
          var rows = await dbSelect('closes', {
            select: 'id,status',
            filters: { id: 'eq.' + closeId },
            useCache: false
          });
          if (rows && rows.length > 0) {
            var status = rows[0].status;
            if (status === 'APPROVED') {
              if (_closePollingInterval) { clearInterval(_closePollingInterval); _closePollingInterval = null; }
              if (cancelBtn) cancelBtn.style.display = 'none';
              refreshCloseBtn.style.display = 'none';
              if (submitBtn) {
                submitBtn.style.background = '#4caf50';
                submitBtn.style.color = '#fff';
                submitBtn.textContent = '✅ ตกลง';
                submitBtn.disabled = false;
                submitBtn.onclick = function() {
                  _closeWorkLocked = false;
                  closeModal('closeWorkModal');
                  logout();
                };
              }
            } else if (status === 'REJECTED') {
              if (_closePollingInterval) { clearInterval(_closePollingInterval); _closePollingInterval = null; }
              if (cancelBtn) cancelBtn.style.display = 'none';
              refreshCloseBtn.style.display = 'none';
              if (submitBtn) {
                submitBtn.style.background = '#f44336';
                submitBtn.style.color = '#fff';
                submitBtn.textContent = '❌ ปฏิเสธ - กดเพื่อรับทราบ';
                submitBtn.disabled = false;
                submitBtn.onclick = function() {
                  _closeWorkLocked = false;
                  closeModal('closeWorkModal');
                };
              }
            } else {
              showToast('⏳ ยังไม่ได้รับการอนุมัติ');
            }
          }
        } catch(e) {}
        refreshCloseBtn.textContent = '↻ รีเฟรช';
        refreshCloseBtn.disabled = false;
      };

      window.currentCloseSummary = null;
      startClosePolling();
    } else {
      alert('❌ ' + (result && result.message ? result.message : 'ส่ง Close ไม่สำเร็จ'));
      // server อาจแจ้งว่ามี close ของวันนี้อยู่แล้ว — เช็คสถานะล่าสุดมาแสดงต่อ
      checkAndResumePendingClose();
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

function startClosePolling() {
  if (_closePollingInterval) clearInterval(_closePollingInterval);
  _closePollingInterval = setInterval(async function() {
    if (!currentCloseId) return;
    try {
      var btn = document.getElementById('closeRefreshBtn');
      if (btn && btn.onclick) btn.onclick();
    } catch(e) {}
  }, 15000);
}

function startAutoRefresh() { startClosePolling(); }
function stopAutoRefresh() {
  if (_closePollingInterval) { clearInterval(_closePollingInterval); _closePollingInterval = null; }
}

async function checkPendingClose() {
  var closeBtn = document.getElementById('closeWorkBtn');
  var reviewBtn = document.getElementById('reviewCloseBtn');

  if (!currentUser) {
    if (closeBtn) closeBtn.style.display = 'none';
    if (reviewBtn) reviewBtn.style.display = 'none';
    var tcBtn = document.getElementById('transferCashBtn');
    if (tcBtn) tcBtn.style.display = 'none';
    return;
  }

  if (isManager()) {
    if (closeBtn) closeBtn.style.display = 'none';
    var tcBtn2 = document.getElementById('transferCashBtn');
    if (tcBtn2) tcBtn2.style.display = 'none';
    try {
      var pendings = await dbRpc('get_pending_closes_for_manager', {});
      var pendingCount = Array.isArray(pendings) ? pendings.length : 0;
      if (pendingCount > 0 && reviewBtn) {
        reviewBtn.style.display = 'inline-block';
        reviewBtn.textContent = '📋 Review Close (' + pendingCount + ')';
      } else if (reviewBtn) {
        reviewBtn.style.display = 'none';
      }
    } catch (e) {
      console.error('Error checking pending close:', e);
      if (reviewBtn) reviewBtn.style.display = 'none';
    }
  } else {
    if (closeBtn) closeBtn.style.display = 'inline-block';
    if (reviewBtn) reviewBtn.style.display = 'none';
    var tcBtn3 = document.getElementById('transferCashBtn');
    if (tcBtn3) tcBtn3.style.display = 'inline-block';
  }
}

async function openReviewCloseModal() {
  try {
    showLoading();
    var pendings = await dbRpc('get_pending_closes_for_manager', {});
    hideLoading();

    if (!Array.isArray(pendings) || pendings.length === 0) {
      document.getElementById('reviewCloseList').innerHTML = '<p style="text-align:center;color:var(--text-secondary);padding:40px;">ไม่มีรายการ Close ที่รอการอนุมัติ</p>';
    } else {
      var rows = pendings.map(function(p) {
        return '<tr><td>' + p.id + '</td><td>' + p.nickname + '</td><td>' + formatDateOnly(p.date) + '</td><td>' + formatDateTime(p.created_at) + '</td><td><button class="btn-primary" style="padding:5px 15px;" onclick="openCloseDetail(\'' + p.id + '\')">Review</button></td></tr>';
      }).join('');
      document.getElementById('reviewCloseList').innerHTML =
        '<table class="data-table" style="width:100%;"><thead><tr><th>ID</th><th>User</th><th>Date</th><th>Time</th><th>Action</th></tr></thead><tbody>' + rows + '</tbody></table>';
    }
    openModal('reviewCloseModal');
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

async function openCloseDetail(closeId) {
  try {
    showLoading();
    currentCloseId = closeId;
    var rows = await dbSelect('closes', {
      select: 'id,user_id,date,cash_summary,bank_summary,gold_summary,total_tx,total_amount,note,created_at,user:users!user_id(nickname)',
      filters: { id: 'eq.' + closeId },
      limit: 1,
      useCache: false
    });
    hideLoading();

    if (!rows || rows.length === 0) {
      alert('ไม่พบข้อมูล');
      return;
    }

    var c = rows[0];
    var productNames = { 'G01': '10 บาท', 'G02': '5 บาท', 'G03': '2 บาท', 'G04': '1 บาท', 'G05': '2 สลึง', 'G06': '1 สลึง', 'G07': '1 กรัม' };
    var cash = c.cash_summary || {};
    var goldSummary = c.gold_summary || {};
    var oldIn = goldSummary.oldIn || {};

    var buildGoldRows = function(obj) {
      var html = '';
      var hasData = false;
      Object.keys(obj).sort().forEach(function(pid) {
        if (obj[pid] > 0) {
          hasData = true;
          html += '<tr><td style="padding:6px 0;">' + (productNames[pid] || pid) + '</td><td style="text-align:right;font-weight:bold;padding:6px 0;">' + obj[pid] + ' ชิ้น</td></tr>';
        }
      });
      return hasData ? html : '<tr><td colspan="2" style="text-align:center;color:var(--text-secondary);padding:15px 0;">ไม่มี</td></tr>';
    };

    document.getElementById('closeDetailContent').innerHTML =
      '<div style="text-align:center;margin-bottom:20px;">' +
      '<p style="font-size:20px;color:var(--gold-primary);font-weight:bold;">' + (c.user ? c.user.nickname : '') + '</p>' +
      '<p style="color:var(--text-secondary);">Close ID: ' + c.id + ' — ส่งเมื่อ: ' + formatDateTime(c.created_at) + '</p>' +
      '</div>' +
      '<div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;">' +
      '<div class="stat-card" style="padding:20px;">' +
      '<h3 style="color:var(--gold-primary);margin-bottom:5px;font-size:15px;">💵 เงินสดที่ถือทั้งหมด</h3>' +
      '<p style="font-size:11px;color:var(--text-secondary);margin:0 0 12px 0;">รวมยอดยกมาจากวันก่อน — ยอดนี้จะถูกโอนเข้าร้านเมื่ออนุมัติ</p>' +
      '<table style="width:100%;border-collapse:collapse;">' +
      '<tr><td style="padding:6px 0;">LAK</td><td style="text-align:right;font-weight:bold;font-size:18px;padding:6px 0;">' + formatNumber(cash.LAK || 0) + '</td></tr>' +
      '<tr><td style="padding:6px 0;">THB</td><td style="text-align:right;font-weight:bold;font-size:18px;padding:6px 0;">' + formatNumber(cash.THB || 0) + '</td></tr>' +
      '<tr><td style="padding:6px 0;">USD</td><td style="text-align:right;font-weight:bold;font-size:18px;padding:6px 0;">' + formatNumber(cash.USD || 0) + '</td></tr>' +
      '</table></div>' +
      '<div class="stat-card" style="padding:20px;">' +
      '<h3 style="color:#ff9800;margin-bottom:15px;font-size:15px;">🥇 ทองเก่า (IN)</h3>' +
      '<table style="width:100%;border-collapse:collapse;">' + buildGoldRows(oldIn) + '</table>' +
      '</div></div>';

    closeModal('reviewCloseModal');
    openModal('closeDetailModal');
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

async function approveClose() {
  if (!currentCloseId) return;
  try {
    showLoading();
    var result = await dbRpc('approve_close_report', {
      p_close_id: currentCloseId,
      p_decision: 'APPROVE',
      p_note: ''
    });
    hideLoading();
    if (result && result.success) {
      showToast('✅ อนุมัติ Close สำเร็จ!');
      closeModal('closeDetailModal');
      currentCloseId = null;
      checkPendingClose();
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

async function rejectClose() {
  if (!currentCloseId) return;
  if (!confirm('ปฏิเสธการปิดงาน ' + currentCloseId + '?')) return;
  try {
    showLoading();
    var result = await dbRpc('approve_close_report', {
      p_close_id: currentCloseId,
      p_decision: 'REJECT',
      p_note: ''
    });
    hideLoading();
    if (result && result.success) {
      showToast('✅ ปฏิเสธ Close สำเร็จ');
      closeModal('closeDetailModal');
      currentCloseId = null;
      checkPendingClose();
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

var _transferCashBalances = { LAK: 0, THB: 0, USD: 0 };
var _transferCashCounter = 0;

async function openTransferCashModal() {
  try {
    showLoading();
    var rows = await dbSelect('user_cashbook', {
      select: 'currency,amount,method',
      filters: { user_id: 'eq.' + currentUser.id },
      useCache: false
    });
    hideLoading();

    _transferCashBalances = { LAK: 0, THB: 0, USD: 0 };
    (rows || []).forEach(function(r) {
      if ((r.method || '').toUpperCase() !== 'CASH') return;
      var cur = r.currency;
      if (_transferCashBalances.hasOwnProperty(cur)) {
        _transferCashBalances[cur] += parseFloat(r.amount) || 0;
      }
    });

    document.getElementById('transferCashBalanceAll').innerHTML =
      '<div style="font-size:13px;color:var(--text-secondary);margin-bottom:8px;">ยอดเงินสดของคุณ</div>' +
      '<div style="display:flex;gap:15px;">' +
      '<div><span style="color:var(--text-secondary);font-size:12px;">LAK</span><br><span style="font-weight:bold;font-size:16px;color:var(--gold-primary);">' + formatNumber(_transferCashBalances.LAK) + '</span></div>' +
      '<div><span style="color:var(--text-secondary);font-size:12px;">THB</span><br><span style="font-weight:bold;font-size:16px;color:var(--gold-primary);">' + formatNumber(_transferCashBalances.THB) + '</span></div>' +
      '<div><span style="color:var(--text-secondary);font-size:12px;">USD</span><br><span style="font-weight:bold;font-size:16px;color:var(--gold-primary);">' + formatNumber(_transferCashBalances.USD) + '</span></div>' +
      '</div>';

    document.getElementById('transferCashRows').innerHTML = '';
    _transferCashCounter = 0;
    addTransferCashRow();
    openModal('transferCashModal');
  } catch (e) {
    hideLoading();
    alert('❌ Error: ' + e.message);
  }
}

function addTransferCashRow() {
  _transferCashCounter++;
  var rid = 'tcr_' + _transferCashCounter;
  document.getElementById('transferCashRows').insertAdjacentHTML('beforeend',
    '<div class="product-row" id="' + rid + '" style="display:flex;gap:8px;align-items:center;margin-bottom:8px;">' +
    '<select class="form-select" style="width:90px;"><option value="LAK">LAK</option><option value="THB">THB</option><option value="USD">USD</option></select>' +
    '<input type="number" class="form-input" placeholder="จำนวนเงิน" step="1000" style="flex:1;">' +
    '<button type="button" class="btn-remove" onclick="document.getElementById(\'' + rid + '\').remove()">×</button>' +
    '</div>');
}

async function confirmTransferCashMulti() {
  var rows = document.querySelectorAll('#transferCashRows .product-row');
  var transfers = [];
  rows.forEach(function(row) {
    var currency = row.querySelector('select').value;
    var amount = parseFloat(String(row.querySelector('input').value).replace(/,/g, '')) || 0;
    if (amount > 0) transfers.push({ currency: currency, amount: amount });
  });

  if (transfers.length === 0) {
    alert('❌ กรุณากรอกจำนวนเงิน');
    return;
  }

  for (var i = 0; i < transfers.length; i++) {
    var t = transfers[i];
    var bal = _transferCashBalances[t.currency] || 0;
    if (t.amount > bal) {
      alert('❌ ยอด ' + t.currency + ' ไม่พอ! มี ' + formatNumber(bal) + ' แต่ต้องการ ' + formatNumber(t.amount));
      return;
    }
  }

  var summary = transfers.map(function(t) { return formatNumber(t.amount) + ' ' + t.currency; }).join(', ');
  if (!confirm('ยืนยันย้ายเงินเข้าร้าน?\n' + summary)) return;

  try {
    showLoading();
    var result = await dbRpc('transfer_user_cash_to_shop', { p_transfers: transfers });
    hideLoading();
    if (result && result.success) {
      showToast('✅ ย้ายเงินเข้าร้านสำเร็จ!');
      closeModal('transferCashModal');
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch (e) {
    hideLoading();
    alert('❌ Error: ' + e.message);
  }
}
