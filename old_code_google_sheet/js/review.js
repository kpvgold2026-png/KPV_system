var currentReviewData = null;

function openReviewDecisionModal(type, id, newGold, oldGold) {
  currentReviewData = { type: type, id: id };

  var titles = {
    'SELL': 'Review Sell',
    'TRADEIN': 'Review Trade-in',
    'EXCHANGE': 'Review Exchange',
    'WITHDRAW': 'Review Withdraw'
  };

  document.getElementById('reviewDecisionTitle').textContent = titles[type] || 'Review';
  document.getElementById('reviewDecisionId').textContent = 'Transaction ID: ' + id;
  document.getElementById('reviewDecisionNote').value = '';

  var buildTable = function(label, color, itemsJson) {
    var html = '<div style="margin-bottom:10px;"><span style="color:' + color + ';font-weight:bold;font-size:13px;">' + label + '</span></div>';
    html += '<table style="width:100%;font-size:14px;margin-bottom:12px;">';
    html += '<tr style="border-bottom:1px solid var(--border-color);"><th style="text-align:left;padding:5px;">Product</th><th style="text-align:right;padding:5px;">Qty</th></tr>';
    try {
      var items = typeof itemsJson === 'string' ? JSON.parse(itemsJson) : itemsJson;
      if (items && items.length > 0) {
        items.forEach(function(item) {
          var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
          var name = p ? p.name : item.productId;
          html += '<tr><td style="padding:5px;">' + name + '</td><td style="text-align:right;padding:5px;">' + item.qty + '</td></tr>';
        });
      } else {
        html += '<tr><td colspan="2" style="padding:5px;color:var(--text-secondary);">ไม่มี</td></tr>';
      }
    } catch(e) {
      html += '<tr><td colspan="2" style="padding:5px;color:var(--text-secondary);">ไม่มี</td></tr>';
    }
    html += '</table>';
    return html;
  };

  var content = '';

  if (oldGold) {
    content += buildTable('◀ ทองเก่า (OLD GOLD)', '#ff9800', oldGold);
  }

  content += buildTable('▶ ทองใหม่ (NEW GOLD)', '#4caf50', newGold);

  document.getElementById('reviewDecisionItems').innerHTML = content;
  openModal('reviewDecisionModal');
}

async function submitReviewDecision(decision) {
  if (!currentReviewData) return;

  var note = document.getElementById('reviewDecisionNote').value.trim();

  var actionMap = {
    'SELL': 'REVIEW_SELL',
    'TRADEIN': 'REVIEW_TRADEIN',
    'EXCHANGE': 'REVIEW_EXCHANGE',
    'WITHDRAW': 'REVIEW_WITHDRAW'
  };

  var action = actionMap[currentReviewData.type];
  if (!action) {
    alert('❌ Unknown transaction type');
    return;
  }

  try {
    showLoading();

    var result = await callAppsScript(action, {
      id: currentReviewData.id,
      decision: decision,
      approvedBy: currentUser.nickname,
      note: note
    });

    if (result.success) {
      var msg = decision === 'APPROVE' ? '✅ Approved!' : '❌ Rejected!';
      if (decision === 'APPROVE') { showToast(msg); } else { alert(msg); }
      closeModal('reviewDecisionModal');

      var type = currentReviewData.type;
      currentReviewData = null;

      if (type === 'SELL') loadSells();
      else if (type === 'TRADEIN') loadTradeins();
      else if (type === 'EXCHANGE') loadExchanges();
      else if (type === 'WITHDRAW') loadWithdraws();

      if (typeof loadHistorySell === 'function') loadHistorySell();
      loadDashboard();
    } else {
      alert('❌ Error: ' + result.message);
    }

    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

async function reviewSell(sellId) {
  try {
    var data = await fetchSheetData('Sells!A:L');
    var sell = data.slice(1).find(function(row) { return row[0] === sellId; });
    if (sell) {
      openReviewDecisionModal('SELL', sellId, sell[2], null);
    }
  } catch (e) {
    alert('❌ Error loading data');
  }
}

async function reviewTradein(tradeinId) {
  try {
    var data = await fetchSheetData('Tradeins!A:N');
    var tradein = data.slice(1).find(function(row) { return row[0] === tradeinId; });
    if (tradein) {
      openReviewDecisionModal('TRADEIN', tradeinId, tradein[3], tradein[2]);
    }
  } catch (e) {
    alert('❌ Error loading data');
  }
}

async function reviewExchange(exchangeId) {
  try {
    var data = await fetchSheetData('Exchanges!A:T');
    var ex = data.slice(1).find(function(row) { return row[0] === exchangeId; });
    if (ex) {
      openReviewDecisionModal('EXCHANGE', exchangeId, ex[3], ex[2]);
    }
  } catch (e) {
    alert('❌ Error loading data');
  }
}

async function reviewWithdraw(withdrawId) {
  try {
    var data = await fetchSheetData('Withdraws!A:J');
    var withdraw = data.slice(1).find(function(row) { return row[0] === withdrawId; });
    if (withdraw) {
      openReviewDecisionModal('WITHDRAW', withdrawId, withdraw[2], null);
    }
  } catch (e) {
    alert('❌ Error loading data');
  }
}