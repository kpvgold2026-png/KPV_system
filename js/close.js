let currentCloseId = null;

async function checkAndResumePendingClose() {
  if (!currentUser || isManager()) return;
  try {
    var today = new Date();
    var todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    var todayEnd = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 23, 59, 59);
    var userName = currentUser.nickname;

    var closeHistory = await fetchSheetData('Close!A:K');
    var myPending = closeHistory.slice(1).find(function(row) {
      var d = parseSheetDate(row[2]);
      var isToday = d && d >= todayStart && d <= todayEnd;
      return isToday && row[1] === userName && row[8] === 'PENDING';
    });

    var myApproved = null;
    if (!myPending) {
      myApproved = closeHistory.slice(1).find(function(row) {
        var d = parseSheetDate(row[2]);
        var isToday = d && d >= todayStart && d <= todayEnd;
        return isToday && row[1] === userName && row[8] === 'APPROVED';
      });
    }

    if (!myPending && !myApproved) return;

    var txResults = await Promise.all([
      fetchSheetData('Sells!A:L'),
      fetchSheetData('Tradeins!A:N'),
      fetchSheetData('Exchanges!A:T'),
      fetchSheetData('Buybacks!A:L'),
      fetchSheetData('Withdraws!A:J'),
      fetchSheetData("'" + userName + "'!A:I"),
      fetchSheetData("'" + userName + "_Gold'!A:F")
    ]);

    var sells = txResults[0], tradeins = txResults[1], exchanges = txResults[2];
    var buybacks = txResults[3], withdraws = txResults[4];
    var userSheetData = txResults[5], userGoldData = txResults[6];

    var isMyToday = function(dateVal, createdBy) {
      var d = parseSheetDate(dateVal);
      return d && d >= todayStart && d <= todayEnd && createdBy === userName;
    };

    var sellMoney = 0, sellGoldG = 0, sellCount = 0;
    var newGoldOut = { G01: 0, G02: 0, G03: 0, G04: 0, G05: 0, G06: 0, G07: 0 };

    var addItems = function(jsonStr, target) {
      try { JSON.parse(jsonStr).forEach(function(item) { if (target[item.productId] !== undefined) target[item.productId] += item.qty; }); } catch(e) {}
    };
    var calcG = function(jsonStr) {
      var t = 0;
      try { JSON.parse(jsonStr).forEach(function(item) { t += (getGoldWeight(item.productId) || 0) * item.qty; }); } catch(e) {}
      return t;
    };

    sells.slice(1).forEach(function(r) {
      if (isMyToday(r[9], r[11]) && (r[10] === 'COMPLETED' || r[10] === 'PAID')) {
        sellMoney += parseFloat(r[3]) || 0; sellGoldG += calcG(r[2]); sellCount++; addItems(r[2], newGoldOut);
      }
    });
    tradeins.slice(1).forEach(function(r) {
      if (isMyToday(r[11], r[13]) && (r[12] === 'COMPLETED' || r[12] === 'PAID')) {
        sellMoney += parseFloat(r[6]) || 0; sellGoldG += calcG(r[3]); sellCount++; addItems(r[3], newGoldOut);
      }
    });
    exchanges.slice(1).forEach(function(r) {
      if (isMyToday(r[11], r[13]) && (r[12] === 'COMPLETED' || r[12] === 'PAID')) {
        sellMoney += parseFloat(r[6]) || 0; sellGoldG += calcG(r[3]); sellCount++; addItems(r[3], newGoldOut);
      }
    });

    var bbGoldG = 0, bbCount = 0;
    var oldGoldReceived = {};
    var bbRefIds = {};
    if (userGoldData && userGoldData.length > 1) {
      for (var gi = 1; gi < userGoldData.length; gi++) {
        var gr = userGoldData[gi];
        var pid = String(gr[0] || '').trim();
        var gqty = parseFloat(gr[1]) || 0;
        var gType = String(gr[2] || '').trim();
        var gRef = String(gr[3] || '').trim();
        if (pid && gqty > 0) {
          oldGoldReceived[pid] = (oldGoldReceived[pid] || 0) + gqty;
          if (gType === 'BUYBACK') {
            bbGoldG += (getGoldWeight(pid) || 0) * gqty;
            if (gRef) bbRefIds[gRef] = true;
          }
        }
      }
    }
    bbCount = Object.keys(bbRefIds).length;

    var bbMoney = 0;
    if (bbCount > 0) {
      buybacks.slice(1).forEach(function(r) {
        if (bbRefIds[r[0]]) {
          bbMoney += parseFloat(r[6]) || parseFloat(r[3]) || 0;
        }
      });
    }

    withdraws.slice(1).forEach(function(r) {
      if (isMyToday(r[6], r[8]) && (r[7] === 'COMPLETED' || r[7] === 'PAID')) { addItems(r[2], newGoldOut); }
    });

    var productNames = { 'G01': '10 บาท', 'G02': '5 บาท', 'G03': '2 บาท', 'G04': '1 บาท', 'G05': '2 สลึง', 'G06': '1 สลึง', 'G07': '1 กรัม' };
    var pids = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06', 'G07'];

    var moneyGrid = { Cash: { LAK: 0, THB: 0, USD: 0 }, BCEL: { LAK: 0, THB: 0, USD: 0 }, LDB: { LAK: 0, THB: 0, USD: 0 }, Other: { LAK: 0, THB: 0, USD: 0 } };
    if (userSheetData && userSheetData.length > 1) {
      for (var i = 1; i < userSheetData.length; i++) {
        var r = userSheetData[i];
        var method = String(r[4] || '').trim();
        var bank = String(r[5] || '').trim();
        var currency = String(r[3] || '').trim();
        var amount = parseFloat(r[2]) || 0;
        if (!currency || !moneyGrid.Cash.hasOwnProperty(currency)) continue;
        if (method === 'Cash') moneyGrid.Cash[currency] += amount;
        else if (method === 'Bank') {
          if (bank === 'BCEL') moneyGrid.BCEL[currency] += amount;
          else if (bank === 'LDB') moneyGrid.LDB[currency] += amount;
          else moneyGrid.Other[currency] += amount;
        }
      }
    }

    var moneyRows = [
      { label: '💵 Cash', key: 'Cash' },
      { label: '🏦 BCEL Bank', key: 'BCEL' },
      { label: '🏦 LDB Bank', key: 'LDB' },
      { label: '🏦 Bank อื่นๆ', key: 'Other' }
    ];
    var moneyTableRows = moneyRows.map(function(m) {
      return '<tr><td style="padding:6px 10px;font-weight:600;">' + m.label + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[m.key].LAK)) + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[m.key].THB)) + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[m.key].USD)) + '</td></tr>';
    }).join('');

    var closeId = myPending ? myPending[0] : myApproved[0];
    var statusLabel = myPending ? '⏳ สถานะ: รอ Manager ยืนยัน' : '✅ สถานะ: Manager ยืนยันแล้ว';
    var statusColor = myPending ? '#d4af37' : '#4caf50';

    document.getElementById('closeWorkSummary').innerHTML =
      '<div style="text-align:center;margin-bottom:15px;">' +
      '<p style="font-size:18px;color:var(--gold-primary);">สรุปยอดประจำวัน</p>' +
      '<p style="color:var(--text-secondary);">' + userName + ' — ' + formatDateOnly(today) + '</p>' +
      '<p style="color:' + statusColor + ';font-weight:bold;margin-top:8px;">' + statusLabel + ' (' + closeId + ')</p>' +
      '</div>' +
      '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:15px;">' +
      '<div class="stat-card" style="text-align:center;">' +
      '<h3 style="color:#4caf50;margin-bottom:8px;">💰 ยอดทองที่ขาย</h3>' +
      '<p style="font-size:20px;font-weight:bold;margin:4px 0;">' + formatNumber(Math.round(sellMoney)) + ' <span style="font-size:12px;">LAK</span></p>' +
      '<p style="font-size:14px;color:var(--text-secondary);margin:2px 0;">' + sellGoldG.toFixed(2) + ' g</p>' +
      '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">' + sellCount + ' บิล</p></div>' +
      '<div class="stat-card" style="text-align:center;">' +
      '<h3 style="color:#ff9800;margin-bottom:8px;">🔄 ยอดทองที่ซื้อคืน</h3>' +
      '<p style="font-size:20px;font-weight:bold;margin:4px 0;">' + formatNumber(Math.round(bbMoney)) + ' <span style="font-size:12px;">LAK</span></p>' +
      '<p style="font-size:14px;color:var(--text-secondary);margin:2px 0;">' + bbGoldG.toFixed(2) + ' g</p>' +
      '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">' + bbCount + ' บิล</p></div></div>' +
      '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:15px;">' +
      '<div class="stat-card" style="padding:15px;">' +
      '<h3 style="color:#4caf50;margin-bottom:10px;font-size:14px;">▶ ทองใหม่ที่จ่ายออก</h3>' +
      '<table style="width:100%;border-collapse:collapse;">' +
      pids.map(function(pid) { return '<tr><td style="padding:4px 10px;">' + productNames[pid] + '</td><td style="padding:4px 10px;text-align:center;font-weight:bold;">' + newGoldOut[pid] + '</td></tr>'; }).join('') +
      '</table></div>' +
      '<div class="stat-card" style="padding:15px;">' +
      '<h3 style="color:#ff9800;margin-bottom:10px;font-size:14px;">◀ ทองเก่าที่ได้รับ</h3>' +
      '<table style="width:100%;border-collapse:collapse;">' +
      pids.map(function(pid) { return '<tr><td style="padding:4px 10px;">' + productNames[pid] + '</td><td style="padding:4px 10px;text-align:center;font-weight:bold;">' + (oldGoldReceived[pid] || 0) + '</td></tr>'; }).join('') +
      '</table></div></div>' +
      '<div class="stat-card" style="padding:15px;margin-bottom:15px;">' +
      '<h3 style="color:var(--gold-primary);margin-bottom:10px;font-size:14px;">💰 สรุปเงินทั้งหมด</h3>' +
      '<table style="width:100%;border-collapse:collapse;">' +
      '<tr style="border-bottom:2px solid var(--border-color);"><th style="padding:6px 10px;text-align:left;color:var(--text-secondary);font-size:12px;">ประเภท</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">LAK</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">THB</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">USD</th></tr>' +
      moneyTableRows + '</table></div>';

    var cancelBtn = document.getElementById('closeWorkCancelBtn');
    var submitBtn = document.getElementById('closeWorkSubmitBtn');

    if (myApproved) {
      if (cancelBtn) cancelBtn.style.display = 'none';
      if (submitBtn) {
        submitBtn.style.background = '#4caf50';
        submitBtn.style.color = '#fff';
        submitBtn.textContent = '✅ ตกลง';
        submitBtn.disabled = false;
        submitBtn.onclick = function() { _closeWorkLocked = false; closeModal('closeWorkModal'); logout(); };
      }
    } else {
      if (cancelBtn) {
        cancelBtn.style.display = 'inline-block';
        cancelBtn.textContent = '❌ ยกเลิกปิดกะ';
        cancelBtn.style.background = '#f44336';
        cancelBtn.style.color = '#fff';
        cancelBtn.onclick = function() { cancelPendingClose(closeId); };
      }
      if (submitBtn) {
        submitBtn.onclick = null;
        submitBtn.style.background = '#d4af37';
        submitBtn.style.color = '#000';
        submitBtn.textContent = '⏳ รอ Manager ยืนยัน...';
        submitBtn.disabled = true;
      }
      startClosePolling();
    }

    _closeWorkLocked = true;
    openModal('closeWorkModal');
    var modal = document.getElementById('closeWorkModal');
    if (modal) modal.onclick = function(e) { e.stopImmediatePropagation(); };

  } catch(e) { console.error('checkAndResumePendingClose error:', e); }
}

async function cancelPendingClose(closeId) {
  if (!confirm('ยืนยันยกเลิกการปิดกะ ' + closeId + ' ?')) return;
  try {
    showLoading();
    var result = await callAppsScript('CANCEL_CLOSE', { closeId: closeId });
    hideLoading();
    if (result.success) {
      showToast('✅ ยกเลิกปิดกะสำเร็จ');
      if (_closePollingInterval) { clearInterval(_closePollingInterval); _closePollingInterval = null; }
      _closeWorkLocked = false;

      var modal = document.getElementById('closeWorkModal');
      if (modal) modal.onclick = null;

      var cancelBtn = document.getElementById('closeWorkCancelBtn');
      if (cancelBtn) { cancelBtn.style.display = 'inline-block'; cancelBtn.textContent = 'Cancel'; cancelBtn.style.background = ''; cancelBtn.style.color = ''; cancelBtn.onclick = function() { closeModal('closeWorkModal'); }; }

      var submitBtn = document.getElementById('closeWorkSubmitBtn');
      if (submitBtn) { submitBtn.style.background = '#c62828'; submitBtn.style.color = '#fff'; submitBtn.textContent = 'Submit Close'; submitBtn.disabled = false; submitBtn.onclick = function() { submitCloseWork(); }; }

      closeModal('closeWorkModal');
    } else {
      alert('❌ ' + result.message);
    }
  } catch(e) { hideLoading(); alert('❌ ' + e.message); }
}

async function openCloseWorkModal() {
  try {
    showLoading();

    var today = new Date();
    var todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    var todayEnd = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 23, 59, 59);
    var userName = currentUser.nickname;

    var closeHistory = await fetchSheetData('Close!A:K');
    var alreadyClosed = closeHistory.slice(1).find(function(row) {
      var d = parseSheetDate(row[2]);
      var isToday = d && d >= todayStart && d <= todayEnd;
      return isToday && row[1] === userName && (row[8] === 'PENDING' || row[8] === 'APPROVED');
    });
    if (alreadyClosed) {
      hideLoading();
      alert('❌ คุณได้ปิดงานวันนี้แล้ว (' + alreadyClosed[0] + ' - ' + alreadyClosed[8] + ')');
      return;
    }

    var txResults = await Promise.all([
      fetchSheetData('Sells!A:L'),
      fetchSheetData('Tradeins!A:N'),
      fetchSheetData('Exchanges!A:T'),
      fetchSheetData('Buybacks!A:L'),
      fetchSheetData('Withdraws!A:J'),
      fetchSheetData("'" + userName + "'!A:I"),
      fetchSheetData("'" + userName + "_Gold'!A:F")
    ]);

    var sells = txResults[0], tradeins = txResults[1], exchanges = txResults[2];
    var buybacks = txResults[3], withdraws = txResults[4];
    var userSheetData = txResults[5], userGoldData = txResults[6];

    var isMyToday = function(dateVal, createdBy) {
      var d = parseSheetDate(dateVal);
      return d && d >= todayStart && d <= todayEnd && createdBy === userName;
    };

    var sellMoney = 0, sellGoldG = 0, sellCount = 0;
    var newGoldOut = { G01: 0, G02: 0, G03: 0, G04: 0, G05: 0, G06: 0, G07: 0 };

    var addItems = function(jsonStr, target) {
      try { JSON.parse(jsonStr).forEach(function(item) { if (target[item.productId] !== undefined) target[item.productId] += item.qty; }); } catch(e) {}
    };
    var calcG = function(jsonStr) {
      var t = 0;
      try { JSON.parse(jsonStr).forEach(function(item) { t += (getGoldWeight(item.productId) || 0) * item.qty; }); } catch(e) {}
      return t;
    };

    sells.slice(1).forEach(function(r) {
      if (isMyToday(r[9], r[11]) && (r[10] === 'COMPLETED' || r[10] === 'PAID')) {
        sellMoney += parseFloat(r[3]) || 0;
        sellGoldG += calcG(r[2]);
        sellCount++;
        addItems(r[2], newGoldOut);
      }
    });

    tradeins.slice(1).forEach(function(r) {
      if (isMyToday(r[11], r[13]) && (r[12] === 'COMPLETED' || r[12] === 'PAID')) {
        sellMoney += parseFloat(r[6]) || 0;
        sellGoldG += calcG(r[3]);
        sellCount++;
        addItems(r[3], newGoldOut);
      }
    });

    exchanges.slice(1).forEach(function(r) {
      if (isMyToday(r[11], r[13]) && (r[12] === 'COMPLETED' || r[12] === 'PAID')) {
        sellMoney += parseFloat(r[6]) || 0;
        sellGoldG += calcG(r[3]);
        sellCount++;
        addItems(r[3], newGoldOut);
      }
    });

    var bbGoldG = 0, bbCount = 0;
    var oldGoldReceived = {};
    var bbRefIds = {};
    if (userGoldData && userGoldData.length > 1) {
      for (var gi = 1; gi < userGoldData.length; gi++) {
        var gr = userGoldData[gi];
        var pid = String(gr[0] || '').trim();
        var gqty = parseFloat(gr[1]) || 0;
        var gType = String(gr[2] || '').trim();
        var gRef = String(gr[3] || '').trim();
        if (pid && gqty > 0) {
          oldGoldReceived[pid] = (oldGoldReceived[pid] || 0) + gqty;
          if (gType === 'BUYBACK') {
            bbGoldG += (getGoldWeight(pid) || 0) * gqty;
            if (gRef) bbRefIds[gRef] = true;
          }
        }
      }
    }
    bbCount = Object.keys(bbRefIds).length;

    var bbMoney = 0;
    if (bbCount > 0) {
      var buybacks = txResults[3];
      buybacks.slice(1).forEach(function(r) {
        if (bbRefIds[r[0]]) {
          bbMoney += parseFloat(r[6]) || parseFloat(r[3]) || 0;
        }
      });
    }

    withdraws.slice(1).forEach(function(r) {
      if (isMyToday(r[6], r[8]) && (r[7] === 'COMPLETED' || r[7] === 'PAID')) {
        addItems(r[2], newGoldOut);
      }
    });

    var productNames = {
      'G01': '10 บาท', 'G02': '5 บาท', 'G03': '2 บาท', 'G04': '1 บาท',
      'G05': '2 สลึง', 'G06': '1 สลึง', 'G07': '1 กรัม'
    };
    var pids = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06', 'G07'];

    var moneyGrid = { Cash: { LAK: 0, THB: 0, USD: 0 }, BCEL: { LAK: 0, THB: 0, USD: 0 }, LDB: { LAK: 0, THB: 0, USD: 0 }, Other: { LAK: 0, THB: 0, USD: 0 } };
    if (userSheetData && userSheetData.length > 1) {
      for (var i = 1; i < userSheetData.length; i++) {
        var r = userSheetData[i];
        var method = String(r[4] || '').trim();
        var bank = String(r[5] || '').trim();
        var currency = String(r[3] || '').trim();
        var amount = parseFloat(r[2]) || 0;
        if (!currency || !moneyGrid.Cash.hasOwnProperty(currency)) continue;
        if (method === 'Cash') {
          moneyGrid.Cash[currency] += amount;
        } else if (method === 'Bank') {
          if (bank === 'BCEL') moneyGrid.BCEL[currency] += amount;
          else if (bank === 'LDB') moneyGrid.LDB[currency] += amount;
          else moneyGrid.Other[currency] += amount;
        }
      }
    }

    var moneyRows = [
      { label: '💵 Cash', key: 'Cash' },
      { label: '🏦 BCEL Bank', key: 'BCEL' },
      { label: '🏦 LDB Bank', key: 'LDB' },
      { label: '🏦 Bank อื่นๆ', key: 'Other' }
    ];
    var moneyTableRows = moneyRows.map(function(m) {
      return '<tr>' +
        '<td style="padding:6px 10px;font-weight:600;">' + m.label + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[m.key].LAK)) + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[m.key].THB)) + '</td>' +
        '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(moneyGrid[m.key].USD)) + '</td>' +
        '</tr>';
    }).join('');

    document.getElementById('closeWorkSummary').innerHTML =
      '<div style="text-align:center;margin-bottom:20px;">' +
      '<p style="font-size:18px;color:var(--gold-primary);">สรุปยอดประจำวัน</p>' +
      '<p style="color:var(--text-secondary);">' + userName + ' — ' + formatDateOnly(today) + '</p>' +
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
      '<table style="width:100%;border-collapse:collapse;">' +
      '<tr style="border-bottom:1px solid var(--border-color);"><th style="padding:5px 10px;text-align:left;color:var(--text-secondary);font-size:12px;">Product</th><th style="padding:5px 10px;text-align:center;color:var(--text-secondary);font-size:12px;">Unit</th>' +
      '<th style="padding:5px 10px;text-align:left;color:var(--text-secondary);font-size:12px;visibility:hidden;">-</th><th style="padding:5px 10px;text-align:center;color:var(--text-secondary);font-size:12px;visibility:hidden;">-</th></tr>' +
      pids.map(function(pid) {
        return '<tr><td style="padding:4px 10px;">' + productNames[pid] + '</td><td style="padding:4px 10px;text-align:center;font-weight:bold;">' + newGoldOut[pid] + '</td>' +
          '<td style="visibility:hidden;">-</td><td style="visibility:hidden;">-</td></tr>';
      }).join('') +
      '</table></div>' +
      '<div class="stat-card" style="padding:15px;">' +
      '<h3 style="color:#ff9800;margin-bottom:10px;font-size:14px;">◀ ทองเก่าที่ได้รับ</h3>' +
      '<table style="width:100%;border-collapse:collapse;">' +
      '<tr style="border-bottom:1px solid var(--border-color);"><th style="padding:5px 10px;text-align:left;color:var(--text-secondary);font-size:12px;">Product</th><th style="padding:5px 10px;text-align:center;color:var(--text-secondary);font-size:12px;">Unit</th>' +
      '<th style="padding:5px 10px;text-align:left;color:var(--text-secondary);font-size:12px;visibility:hidden;">-</th><th style="padding:5px 10px;text-align:center;color:var(--text-secondary);font-size:12px;visibility:hidden;">-</th></tr>' +
      pids.map(function(pid) {
        return '<tr><td style="padding:4px 10px;">' + productNames[pid] + '</td><td style="padding:4px 10px;text-align:center;font-weight:bold;">' + (oldGoldReceived[pid] || 0) + '</td>' +
          '<td style="visibility:hidden;">-</td><td style="visibility:hidden;">-</td></tr>';
      }).join('') +
      '</table></div>' +
      '</div>' +

      '<div class="stat-card" style="padding:15px;margin-bottom:15px;">' +
      '<h3 style="color:var(--gold-primary);margin-bottom:10px;font-size:14px;">💰 สรุปเงินทั้งหมด</h3>' +
      '<table style="width:100%;border-collapse:collapse;">' +
      '<tr style="border-bottom:2px solid var(--border-color);"><th style="padding:6px 10px;text-align:left;color:var(--text-secondary);font-size:12px;">ประเภท</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">LAK</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">THB</th><th style="padding:6px 10px;text-align:right;color:var(--text-secondary);font-size:12px;">USD</th></tr>' +
      moneyTableRows +
      '</table></div>';

    window.currentCloseSummary = {
      user: userName,
      date: today.toISOString(),
      cashLAK: moneyGrid.Cash.LAK,
      cashTHB: moneyGrid.Cash.THB,
      cashUSD: moneyGrid.Cash.USD,
      oldGold: JSON.stringify(oldGoldReceived)
    };

    hideLoading();
    openModal('closeWorkModal');
  } catch (error) {
    console.error('Error opening close work modal:', error);
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

var _closePollingInterval = null;

async function submitCloseWork() {
  if (!window.currentCloseSummary) return;

  try {
    showLoading();
    var result = await callAppsScript('SUBMIT_CLOSE', window.currentCloseSummary);
    if (result.success) {
      showToast('✅ ส่ง Close สำเร็จ! รอ Manager อนุมัติ');

      _closeWorkLocked = true;
      var closeId = (result.data && result.data.closeId) || '';

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

      var modal = document.getElementById('closeWorkModal');
      if (modal) modal.onclick = function(e) { e.stopImmediatePropagation(); };

      window.currentCloseSummary = null;
      startClosePolling();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

function startClosePolling() {
  if (_closePollingInterval) clearInterval(_closePollingInterval);
  _closePollingInterval = setInterval(async function() {
    try {
      var closeData = await fetchSheetData('Close!A:K');
      var userName = currentUser.nickname;
      var today = new Date();
      var todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate());
      var todayEnd = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 23, 59, 59);

      var myClose = closeData.slice(1).find(function(row) {
        var d = parseSheetDate(row[2]);
        return d && d >= todayStart && d <= todayEnd && row[1] === userName;
      });

      if (myClose && myClose[8] === 'APPROVED') {
        clearInterval(_closePollingInterval);
        _closePollingInterval = null;

        var cancelBtn = document.getElementById('closeWorkCancelBtn');
        if (cancelBtn) cancelBtn.style.display = 'none';

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
    } catch(e) {}
  }, 5000);
}

var _autoRefreshInterval = null;

function startAutoRefresh() {
  stopAutoRefresh();
  _autoRefreshInterval = setInterval(function() {
    checkPendingClose();
    if (typeof loadPendingTransferCount === 'function') loadPendingTransferCount();
  }, 30000);
}

function stopAutoRefresh() {
  if (_autoRefreshInterval) {
    clearInterval(_autoRefreshInterval);
    _autoRefreshInterval = null;
  }
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
      var closeData = await fetchSheetData('Close!A:K');
      var pendingCount = closeData.slice(1).filter(function(row) { return row[8] === 'PENDING'; }).length;

      if (pendingCount > 0) {
        reviewBtn.style.display = 'inline-block';
        reviewBtn.textContent = '📋 Review Close (' + pendingCount + ')';
      } else {
        reviewBtn.style.display = 'none';
      }
    } catch (error) {
      console.error('Error checking pending close:', error);
      reviewBtn.style.display = 'none';
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

    var closeData = await fetchSheetData('Close!A:K');
    var pendingCloses = closeData.slice(1).filter(function(row) { return row[8] === 'PENDING'; });

    if (pendingCloses.length === 0) {
      document.getElementById('reviewCloseList').innerHTML = '<p style="text-align:center;color:var(--text-secondary);padding:40px;">ไม่มีรายการ Close ที่รอการอนุมัติ</p>';
    } else {
      var rows = pendingCloses.map(function(row) {
        return '<tr><td>' + row[0] + '</td><td>' + row[1] + '</td><td>' + formatDateOnly(parseSheetDate(row[2])) + '</td><td>' + formatDateTime(row[7]) + '</td><td><button class="btn-primary" style="padding:5px 15px;" onclick="openCloseDetail(\'' + row[0] + '\')">Review</button></td></tr>';
      }).join('');
      document.getElementById('reviewCloseList').innerHTML =
        '<table class="data-table" style="width:100%;"><thead><tr><th>ID</th><th>User</th><th>Date</th><th>Time</th><th>Action</th></tr></thead><tbody>' + rows + '</tbody></table>';
    }

    hideLoading();
    openModal('reviewCloseModal');
  } catch (error) {
    console.error('Error opening review close modal:', error);
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

async function openCloseDetail(closeId) {
  try {
    showLoading();
    currentCloseId = closeId;

    var closeData = await fetchSheetData('Close!A:K');
    var closeRecord = closeData.slice(1).find(function(row) { return row[0] === closeId; });

    if (!closeRecord) {
      alert('ไม่พบข้อมูล');
      hideLoading();
      return;
    }

    var productNames = {
      'G01': '10 บาท', 'G02': '5 บาท', 'G03': '2 บาท', 'G04': '1 บาท',
      'G05': '2 สลึง', 'G06': '1 สลึง', 'G07': '1 กรัม'
    };

    var buildGoldTable = function(jsonStr) {
      var html = '';
      var hasData = false;
      try {
        var obj = JSON.parse(jsonStr);
        Object.keys(obj).sort().forEach(function(pid) {
          if (obj[pid] > 0) {
            hasData = true;
            html += '<tr><td style="padding:6px 0;white-space:nowrap;">' + (productNames[pid] || pid) + '</td><td style="text-align:right;font-weight:bold;padding:6px 0;white-space:nowrap;">' + obj[pid] + ' ชิ้น</td></tr>';
          }
        });
      } catch(e) {}
      return hasData ? html : '<tr><td colspan="2" style="text-align:center;color:var(--text-secondary);padding:15px 0;">ไม่มี</td></tr>';
    };

    document.getElementById('closeDetailContent').innerHTML =
      '<div style="text-align:center;margin-bottom:20px;">' +
      '<p style="font-size:20px;color:var(--gold-primary);font-weight:bold;">' + closeRecord[1] + '</p>' +
      '<p style="color:var(--text-secondary);">Close ID: ' + closeRecord[0] + ' — ส่งเมื่อ: ' + formatDateTime(closeRecord[7]) + '</p>' +
      '</div>' +
      '<div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;">' +
      '<div class="stat-card" style="padding:20px;">' +
      '<h3 style="color:var(--gold-primary);margin-bottom:15px;font-size:15px;white-space:nowrap;">💵 เงินสด</h3>' +
      '<table style="width:100%;border-collapse:collapse;">' +
      '<tr><td style="padding:6px 0;">LAK</td><td style="text-align:right;font-weight:bold;font-size:18px;padding:6px 0;">' + formatNumber(closeRecord[3]) + '</td></tr>' +
      '<tr><td style="padding:6px 0;">THB</td><td style="text-align:right;font-weight:bold;font-size:18px;padding:6px 0;">' + formatNumber(closeRecord[4]) + '</td></tr>' +
      '<tr><td style="padding:6px 0;">USD</td><td style="text-align:right;font-weight:bold;font-size:18px;padding:6px 0;">' + formatNumber(closeRecord[5]) + '</td></tr>' +
      '</table></div>' +
      '<div class="stat-card" style="padding:20px;">' +
      '<h3 style="color:#ff9800;margin-bottom:15px;font-size:15px;white-space:nowrap;">🥇 ทองเก่า (IN)</h3>' +
      '<table style="width:100%;border-collapse:collapse;">' + buildGoldTable(closeRecord[6]) + '</table>' +
      '</div></div>';

    closeModal('reviewCloseModal');
    hideLoading();
    openModal('closeDetailModal');
  } catch (error) {
    console.error('Error opening close detail:', error);
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

async function approveClose() {
  if (!currentCloseId) return;

  try {
    showLoading();
    var result = await callAppsScript('APPROVE_CLOSE', {
      closeId: currentCloseId,
      approvedBy: currentUser.nickname
    });
    if (result.success) {
      showToast('✅ อนุมัติ Close สำเร็จ!');
      closeModal('closeDetailModal');
      currentCloseId = null;
      checkPendingClose();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

async function rejectClose() {
  if (!currentCloseId) return;
  if (!confirm('ปฏิเสธการปิดงาน ' + currentCloseId + '?')) return;

  try {
    showLoading();
    var result = await callAppsScript('REJECT_CLOSE', {
      closeId: currentCloseId,
      approvedBy: currentUser.nickname
    });
    if (result.success) {
      showToast('✅ ปฏิเสธ Close สำเร็จ');
      closeModal('closeDetailModal');
      currentCloseId = null;
      checkPendingClose();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

var _transferCashBalances = { LAK: 0, THB: 0, USD: 0 };
var _transferCashCounter = 0;

async function openTransferCashModal() {
  try {
    showLoading();
    var userName = currentUser.nickname;
    var userSheetData = await fetchSheetData("'" + userName + "'!A:I");

    _transferCashBalances = { LAK: 0, THB: 0, USD: 0 };
    if (userSheetData && userSheetData.length > 1) {
      for (var i = 1; i < userSheetData.length; i++) {
        var r = userSheetData[i];
        var method = String(r[4] || '').trim();
        var currency = String(r[3] || '').trim();
        var amount = parseFloat(r[2]) || 0;
        if (method === 'Cash' && _transferCashBalances.hasOwnProperty(currency)) {
          _transferCashBalances[currency] += amount;
        }
      }
    }

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

    hideLoading();
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
    var amount = parseFloat(row.querySelector('input').value.replace(/,/g, '')) || 0;
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
    var result = await callAppsScript('TRANSFER_CASH_TO_SHOP', {
      user: currentUser.nickname,
      transfers: JSON.stringify(transfers)
    });

    if (result.success) {
      showToast('✅ ย้ายเงินเข้าร้านสำเร็จ!');
      closeModal('transferCashModal');
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (e) {
    hideLoading();
    alert('❌ Error: ' + e.message);
  }
}
