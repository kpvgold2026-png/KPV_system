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
        var roleLabels = { FOC: 'แถมฟรี (FOC)', SWITCH: 'SWITCH', FREE_EX: 'FREE-EX' };
        items.forEach(function(item) {
          var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
          var name = p ? p.name : item.productId;
          if (item.role && roleLabels[item.role]) {
            name += ' <span style="font-size:11px;color:#9c27b0;font-weight:bold;">[' + roleLabels[item.role] + ']</span>';
          }
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
  if (oldGold) content += buildTable('◀ ทองเก่า (OLD GOLD)', '#ff9800', oldGold);
  content += buildTable('▶ ทองใหม่ (NEW GOLD)', '#4caf50', newGold);

  document.getElementById('reviewDecisionItems').innerHTML = content;
  openModal('reviewDecisionModal');
}

async function submitReviewDecision(decision) {
  if (!currentReviewData) return;
  var note = document.getElementById('reviewDecisionNote').value.trim();

  var rpcMap = {
    'SELL': 'review_sell_tx',
    'TRADEIN': 'review_tradein_tx',
    'EXCHANGE': 'review_exchange_tx',
    'WITHDRAW': 'review_withdraw_tx'
  };
  var rpcName = rpcMap[currentReviewData.type];
  if (!rpcName) { alert('❌ Unknown transaction type'); return; }

  try {
    showLoading();

    if (decision === 'REJECT') {
      var result = await dbRpc('reject_tx', {
        p_tx_id: currentReviewData.id,
        p_note: note
      });
      hideLoading();
      if (result && result.success) {
        alert('❌ Rejected!');
        closeModal('reviewDecisionModal');
        var type = currentReviewData.type;
        currentReviewData = null;
        if (type === 'SELL') loadSells();
        else if (type === 'TRADEIN') loadTradeins();
        else if (type === 'EXCHANGE') loadExchanges();
        else if (type === 'WITHDRAW') loadWithdraws();
        if (typeof loadHistorySell === 'function') loadHistorySell();
        if (typeof loadDashboard === 'function') loadDashboard();
      } else {
        alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
      }
      return;
    }

    var result = await dbRpc(rpcName, { p_tx_id: currentReviewData.id });
    hideLoading();
    if (result && result.success) {
      showToast('✅ Approved!');
      closeModal('reviewDecisionModal');
      var type = currentReviewData.type;
      currentReviewData = null;
      if (type === 'SELL') loadSells();
      else if (type === 'TRADEIN') loadTradeins();
      else if (type === 'EXCHANGE') loadExchanges();
      else if (type === 'WITHDRAW') loadWithdraws();
      if (typeof loadHistorySell === 'function') loadHistorySell();
      if (typeof loadDashboard === 'function') loadDashboard();
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

async function _loadTxItems(txId, roles) {
  var list = Array.isArray(roles) ? roles : [roles];
  var roleFilter = list.length > 1 ? 'in.(' + list.join(',') + ')' : 'eq.' + list[0];
  var rows = await dbSelect('transaction_items', {
    select: 'product_id,qty,item_role',
    filters: { tx_id: 'eq.' + txId, item_role: roleFilter },
    useCache: false
  });
  return (rows || []).map(function(i) { return { productId: i.product_id, qty: i.qty, role: i.item_role }; });
}

async function reviewSell(sellId) {
  try {
    var newItems = await _loadTxItems(sellId, 'NEW');
    openReviewDecisionModal('SELL', sellId, JSON.stringify(newItems), null);
  } catch (e) {
    alert('❌ Error loading data: ' + e.message);
  }
}

async function reviewTradein(tradeinId) {
  try {
    var newItems = await _loadTxItems(tradeinId, 'NEW');
    var oldItems = await _loadTxItems(tradeinId, ['OLD', 'FOC']);
    openReviewDecisionModal('TRADEIN', tradeinId, JSON.stringify(newItems), JSON.stringify(oldItems));
  } catch (e) {
    alert('❌ Error loading data: ' + e.message);
  }
}

async function reviewExchange(exchangeId) {
  try {
    var newItems = await _loadTxItems(exchangeId, 'NEW');
    var oldItems = await _loadTxItems(exchangeId, ['OLD', 'SWITCH', 'FREE_EX']);
    openReviewDecisionModal('EXCHANGE', exchangeId, JSON.stringify(newItems), JSON.stringify(oldItems));
  } catch (e) {
    alert('❌ Error loading data: ' + e.message);
  }
}

async function reviewWithdraw(withdrawId) {
  try {
    var newItems = await _loadTxItems(withdrawId, 'NEW');
    openReviewDecisionModal('WITHDRAW', withdrawId, JSON.stringify(newItems), null);
  } catch (e) {
    alert('❌ Error loading data: ' + e.message);
  }
}
