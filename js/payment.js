let currentPaymentData = null;
let paymentItems = { cash: [], bank: [] };

function openMultiPaymentModal(type, id, total, phone, details) {
  currentPaymentData = { type, id, total, phone, details };
  paymentItems = { cash: [], bank: [] };
  
  const title = type === 'BUYBACK' ? 'Payment Confirmation' : 'Receive Confirmation';
  
  document.getElementById('multiPaymentTitle').textContent = title;
  document.getElementById('multiPaymentId').textContent = id;
  document.getElementById('multiPaymentPhone').textContent = phone;
  document.getElementById('multiPaymentDetails').innerHTML = details;
  document.getElementById('multiPaymentTotal').textContent = formatNumber(total) + ' LAK';
  
  document.getElementById('cashPaymentsList').innerHTML = '';
  document.getElementById('bankPaymentsList').innerHTML = '';
  
  document.getElementById('multiPaymentFeeGroup').style.display = 'none';
  document.getElementById('multiPaymentFeeInput').value = '0';
  
  updatePaymentSummary();
  
  openModal('multiPaymentModal');
}

function addCashPayment() {
  const id = Date.now();
  paymentItems.cash.push({ id, currency: 'LAK', amount: 0, rate: 1 });
  renderCashPayments();
}

function addBankPayment() {
  const id = Date.now();
  paymentItems.bank.push({ id, bank: 'BCEL', currency: 'LAK', amount: 0, rate: 1, fee: 0 });
  renderBankPayments();
}

function renderCashPayments() {
  const container = document.getElementById('cashPaymentsList');
  container.innerHTML = paymentItems.cash.map((item, idx) => {
    const lakAmount = item.amount * item.rate;
    return `
    <div class="payment-item" data-id="${item.id}" style="margin-bottom: 10px; padding: 12px; background: var(--bg-light); border-radius: 8px;">
      <div style="display: flex; gap: 10px; align-items: center;">
        <select class="form-select" style="width: 90px;" onchange="updateCashCurrency(${item.id}, this.value)">
          <option value="LAK" ${item.currency === 'LAK' ? 'selected' : ''}>LAK</option>
          <option value="THB" ${item.currency === 'THB' ? 'selected' : ''}>THB</option>
          <option value="USD" ${item.currency === 'USD' ? 'selected' : ''}>USD</option>
        </select>
        <input type="number" class="form-input cash-amount-input" data-id="${item.id}" placeholder="Amount" value="${item.amount || ''}" 
               style="flex: 1;" oninput="updateCashAmountOnly(${item.id}, this.value)">
        <button class="btn-secondary" style="padding: 8px 12px; background: #f44336; color: white;" onclick="removeCashPayment(${item.id})">✕</button>
      </div>
      ${item.currency !== 'LAK' ? `
        <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 8px; padding-top: 8px; border-top: 1px dashed var(--border-color);">
          <span style="font-size: 11px; color: var(--text-secondary);">Rate: 1 ${item.currency} = ${new Intl.NumberFormat('en-US', {minimumFractionDigits:2, maximumFractionDigits:2}).format(item.rate)} LAK</span>
          <span class="lak-display" style="color: var(--gold-primary); font-weight: bold;">= ${formatNumber(lakAmount)} LAK</span>
        </div>
      ` : ''}
    </div>
  `}).join('');
  updatePaymentSummary();
}

function updateCashAmountOnly(id, value) {
  const item = paymentItems.cash.find(i => i.id === id);
  if (item) {
    item.amount = parseFloat(String(value).replace(/,/g, '')) || 0;
    const lakAmount = item.amount * item.rate;
    const container = document.querySelector(`#cashPaymentsList .payment-item[data-id="${id}"]`);
    if (container && item.currency !== 'LAK') {
      const lakSpan = container.querySelector('.lak-display');
      if (lakSpan) lakSpan.textContent = `= ${formatNumber(lakAmount)} LAK`;
    }
    updatePaymentSummary();
  }
}

function renderBankPayments() {
  const container = document.getElementById('bankPaymentsList');
  var isBuyback = currentPaymentData && currentPaymentData.type === 'BUYBACK';
  container.innerHTML = paymentItems.bank.map((item, idx) => {
    const lakAmount = item.amount * item.rate;
    var feeHtml = '';
    return `
    <div class="payment-item" data-id="${item.id}" style="margin-bottom: 10px; padding: 12px; background: var(--bg-light); border-radius: 8px;">
      <div style="display: flex; gap: 10px; align-items: center; margin-bottom: 8px;">
        <select class="form-select" style="flex: 1;" onchange="updateBankName(${item.id}, this.value)">
          <option value="BCEL" ${item.bank === 'BCEL' ? 'selected' : ''}>BCEL</option>
          <option value="LDB" ${item.bank === 'LDB' ? 'selected' : ''}>LDB</option>
          <option value="OTHER" ${item.bank === 'OTHER' ? 'selected' : ''}>อื่น ๆ</option>
        </select>
        <select class="form-select" style="flex: 1;" onchange="updateBankCurrency(${item.id}, this.value)">
          <option value="LAK" ${item.currency === 'LAK' ? 'selected' : ''}>LAK</option>
          <option value="THB" ${item.currency === 'THB' ? 'selected' : ''}>THB</option>
          <option value="USD" ${item.currency === 'USD' ? 'selected' : ''}>USD</option>
        </select>
        <button class="btn-secondary" style="padding: 8px 12px; background: #f44336; color: white;" onclick="removeBankPayment(${item.id})">✕</button>
      </div>
      <div style="display: flex; gap: 10px; align-items: center;">
        <input type="number" class="form-input bank-amount-input" data-id="${item.id}" placeholder="Amount" value="${item.amount || ''}" 
               style="flex: 1;" oninput="updateBankAmountOnly(${item.id}, this.value)">
      </div>
      ${item.currency !== 'LAK' ? `
        <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 8px; padding-top: 8px; border-top: 1px dashed var(--border-color);">
          <span style="font-size: 11px; color: var(--text-secondary);">Rate: 1 ${item.currency} = ${new Intl.NumberFormat('en-US', {minimumFractionDigits:2, maximumFractionDigits:2}).format(item.rate)} LAK</span>
          <span class="lak-display" style="color: var(--gold-primary); font-weight: bold;">= ${formatNumber(lakAmount)} LAK</span>
        </div>
      ` : ''}
      ${feeHtml}
    </div>
  `}).join('');
  updatePaymentSummary();
}

function updateBankAmountOnly(id, value) {
  const item = paymentItems.bank.find(i => i.id === id);
  if (item) {
    item.amount = parseFloat(String(value).replace(/,/g, '')) || 0;
    const lakAmount = item.amount * item.rate;
    const container = document.querySelector(`#bankPaymentsList .payment-item[data-id="${id}"]`);
    if (container && item.currency !== 'LAK') {
      const lakSpan = container.querySelector('.lak-display');
      if (lakSpan) lakSpan.textContent = `= ${formatNumber(lakAmount)} LAK`;
    }
    updatePaymentSummary();
  }
}

function updateCashCurrency(id, value) {
  const item = paymentItems.cash.find(i => i.id === id);
  if (item) {
    item.currency = value;
    item.rate = value === 'LAK' ? 1 : (value === 'THB' ? (currentPaymentData?.type === 'BUYBACK' ? (currentExchangeRates?.THB_Buy || 0) : (currentExchangeRates?.THB_Sell || 0)) : (currentPaymentData?.type === 'BUYBACK' ? (currentExchangeRates?.USD_Buy || 0) : (currentExchangeRates?.USD_Sell || 0)));
    renderCashPayments();
  }
}

function updateCashAmount(id, value) {
  const item = paymentItems.cash.find(i => i.id === id);
  if (item) {
    item.amount = parseFloat(String(value).replace(/,/g, '')) || 0;
    renderCashPayments();
  }
}

function removeCashPayment(id) {
  paymentItems.cash = paymentItems.cash.filter(i => i.id !== id);
  renderCashPayments();
}

function updateBankName(id, value) {
  const item = paymentItems.bank.find(i => i.id === id);
  if (item) item.bank = value;
}

function updateBankCurrency(id, value) {
  const item = paymentItems.bank.find(i => i.id === id);
  if (item) {
    item.currency = value;
    item.rate = value === 'LAK' ? 1 : (value === 'THB' ? (currentPaymentData?.type === 'BUYBACK' ? (currentExchangeRates?.THB_Buy || 0) : (currentExchangeRates?.THB_Sell || 0)) : (currentPaymentData?.type === 'BUYBACK' ? (currentExchangeRates?.USD_Buy || 0) : (currentExchangeRates?.USD_Sell || 0)));
    renderBankPayments();
  }
}

function updateBankAmount(id, value) {
  const item = paymentItems.bank.find(i => i.id === id);
  if (item) {
    item.amount = parseFloat(String(value).replace(/,/g, '')) || 0;
    renderBankPayments();
  }
}

function removeBankPayment(id) {
  paymentItems.bank = paymentItems.bank.filter(i => i.id !== id);
  renderBankPayments();
}

function updateBankFee(id, value) {
  var item = paymentItems.bank.find(function(i) { return i.id === id; });
  if (item) {
    item.fee = parseFloat(String(value).replace(/,/g, '')) || 0;
    updatePaymentSummary();
  }
}

function updatePaymentSummary() {
  let totalPaid = 0;
  
  paymentItems.cash.forEach(item => {
    totalPaid += item.amount * item.rate;
  });
  
  paymentItems.bank.forEach(item => {
    totalPaid += item.amount * item.rate;
  });
  
  const total = currentPaymentData?.total || 0;
  const remaining = total - totalPaid;
  const change = totalPaid - total;
  var isBuyback = currentPaymentData && currentPaymentData.type === 'BUYBACK';
  
  document.getElementById('multiPaymentPaidTotal').textContent = formatNumber(totalPaid) + ' LAK';
  
  var changeBox = document.getElementById('multiPaymentChangeBox');
  var changeEl = document.getElementById('multiPaymentChange');
  var changeLbl = document.getElementById('multiPaymentChangeLabel');
  var changeNote = document.getElementById('multiPaymentChangeNote');
  var feeBox = document.getElementById('multiPaymentFeeSummary');

  if (isBuyback) {
    changeBox.style.display = 'none';
    if (feeBox) feeBox.style.display = 'none';
  } else {
    changeBox.style.display = '';
    if (feeBox) feeBox.style.display = 'none';
  }
  
  if (remaining > 0) {
    document.getElementById('multiPaymentRemaining').textContent = formatNumber(remaining) + ' LAK';
    document.getElementById('multiPaymentRemaining').style.color = '#f44336';
    if (!isBuyback) {
      changeEl.textContent = '0 LAK';
      changeBox.style.background = 'rgba(76, 175, 80, 0.15)';
      changeBox.style.borderColor = '#4caf50';
      changeLbl.style.color = '#4caf50';
      changeEl.style.color = '#4caf50';
      changeNote.style.display = 'none';
    }
  } else {
    document.getElementById('multiPaymentRemaining').textContent = '0 LAK';
    document.getElementById('multiPaymentRemaining').style.color = '#4caf50';

    if (!isBuyback) {
      var ch = Math.max(0, change);
      ch = Math.round(ch / 1000) * 1000;
      if (ch < 1000) ch = 0;
      changeEl.textContent = formatNumber(ch) + ' LAK';

      var overLimit = false;
      var limitLabel = '';
      if (ch > 0) {
        var allItems = paymentItems.cash.concat(paymentItems.bank);
        var hasTHB = allItems.some(function(i) { return i.currency === 'THB' && i.amount > 0; });
        var hasUSD = allItems.some(function(i) { return i.currency === 'USD' && i.amount > 0; });
        if (hasTHB || hasUSD) {
          var thbRate = currentExchangeRates.THB_Sell || 0;
          var usdRate = currentExchangeRates.USD_Sell || 0;
          var maxLAK = 0;
          if (hasUSD && !hasTHB) {
            maxLAK = 100 * usdRate;
            limitLabel = '100 USD (' + formatNumber(maxLAK) + ' LAK)';
          } else {
            maxLAK = 1000 * thbRate;
            limitLabel = '1,000 THB (' + formatNumber(maxLAK) + ' LAK)';
          }
          if (maxLAK > 0 && ch > maxLAK) overLimit = true;
        }
      }

      if (overLimit) {
        changeBox.style.background = 'rgba(244, 67, 54, 0.15)';
        changeBox.style.borderColor = '#f44336';
        changeLbl.style.color = '#f44336';
        changeEl.style.color = '#f44336';
        changeNote.style.display = 'block';
        changeNote.textContent = '⚠ เงินทอนเกินกำหนด! สูงสุด ' + limitLabel;
      } else {
        changeBox.style.background = 'rgba(76, 175, 80, 0.15)';
        changeBox.style.borderColor = '#4caf50';
        changeLbl.style.color = '#4caf50';
        changeEl.style.color = '#4caf50';
        changeNote.style.display = 'none';
      }
    }
  }
}

async function confirmMultiPayment() {
  if (_isSubmitting) return;
  if (!currentPaymentData) return;
  _isSubmitting = true;
  
  let totalPaid = 0;
  paymentItems.cash.forEach(item => { totalPaid += item.amount * item.rate; });
  paymentItems.bank.forEach(item => { totalPaid += item.amount * item.rate; });
  
  const total = currentPaymentData.total;
  
  if (currentPaymentData.type === 'BUYBACK') {
    if (totalPaid <= 0) {
      alert('❌ กรุณากรอกจำนวนเงินที่จ่าย');
      _isSubmitting = false;
      return;
    }
    if (totalPaid > total) {
      alert('❌ ยอดจ่ายเกิน Total Amount!\nจ่าย: ' + formatNumber(Math.round(totalPaid)) + ' LAK\nTotal: ' + formatNumber(Math.round(total)) + ' LAK\n\nยอดจ่ายต้องน้อยกว่าหรือเท่ากับ Total เท่านั้น');
      _isSubmitting = false;
      return;
    }
  } else {
    if (totalPaid < total) {
      alert('❌ ยอดชำระยังไม่ครบ! ขาดอีก ' + formatNumber(total - totalPaid) + ' LAK');
      _isSubmitting = false;
      return;
    }
  }
  
  var change = 0;
  if (currentPaymentData.type !== 'BUYBACK') {
    change = Math.max(0, totalPaid - total);
    change = Math.round(change / 1000) * 1000;
    if (change < 1000) change = 0;
  }

  if (change > 0) {
    var allItems = paymentItems.cash.concat(paymentItems.bank);
    var hasTHB = allItems.some(function(i) { return i.currency === 'THB' && i.amount > 0; });
    var hasUSD = allItems.some(function(i) { return i.currency === 'USD' && i.amount > 0; });

    if (hasTHB || hasUSD) {
      var thbRate = currentExchangeRates.THB_Sell || 0;
      var usdRate = currentExchangeRates.USD_Sell || 0;
      var maxChangeLAK = 0;
      var maxLabel = '';

      if (hasUSD && !hasTHB) {
        maxChangeLAK = 100 * usdRate;
        maxLabel = '100 USD (' + formatNumber(maxChangeLAK) + ' LAK)';
      } else {
        maxChangeLAK = 1000 * thbRate;
        maxLabel = '1,000 THB (' + formatNumber(maxChangeLAK) + ' LAK)';
      }

      if (maxChangeLAK > 0 && change > maxChangeLAK) {
        alert('❌ เงินทอนเกินกำหนด!\n\nเงินทอน: ' + formatNumber(change) + ' LAK\nเกินกำหนดสูงสุด: ' + maxLabel + '\n\nกรุณาปรับยอดชำระให้เงินทอนไม่เกิน ' + maxLabel);
        _isSubmitting = false;
        return;
      }
    }

    try {
      if (currentPaymentData.type === 'BUYBACK') {
        var dbData = await fetchSheetData('_database!A1:G23');
        var cashLAK = dbData.length >= 17 ? (parseFloat(dbData[16][0]) || 0) : 0;
        if (cashLAK < change) {
          alert('❌ เงินสด LAK ไม่พอทอน! มี ' + formatNumber(cashLAK) + ' LAK แต่ต้องทอน ' + formatNumber(change) + ' LAK');
          _isSubmitting = false;
          hideLoading();
          return;
        }
      } else {
        var sheetName = currentUser.nickname;
        console.log('Fetching user sheet:', sheetName);
        var userSheetData = await fetchSheetData("'" + sheetName + "'!A:I");
        console.log('User sheet rows:', userSheetData ? userSheetData.length : 'null');
        var userCashLAK = 0;
        if (userSheetData && userSheetData.length > 1) {
          for (var ui = 1; ui < userSheetData.length; ui++) {
            var r = userSheetData[ui];
            if (String(r[4]).trim() === 'Cash' && String(r[3]).trim() === 'LAK') {
              userCashLAK += parseFloat(r[2]) || 0;
            }
          }
        }
        console.log('User Cash LAK balance:', userCashLAK);
        if (userCashLAK < change) {
          alert('❌ เงินสด LAK ของคุณไม่พอทอน! มี ' + formatNumber(userCashLAK) + ' LAK แต่ต้องทอน ' + formatNumber(change) + ' LAK');
          _isSubmitting = false;
          hideLoading();
          return;
        }
      }
    } catch(e) {
      console.error('Error checking user cash balance:', e);
      alert('❌ ไม่สามารถตรวจสอบยอดเงินได้: ' + e.message);
      _isSubmitting = false;
      hideLoading();
      return;
    }
  }

  try {
    showLoading();

    var supabaseTypes = ['SELL', 'TRADEIN', 'EXCHANGE', 'WITHDRAW', 'BUYBACK'];
    if (supabaseTypes.indexOf(currentPaymentData.type) !== -1) {
      var rpcMap = {
        'SELL': 'confirm_sell_tx',
        'TRADEIN': 'confirm_tradein_tx',
        'EXCHANGE': 'confirm_exchange_tx',
        'WITHDRAW': 'confirm_withdraw_tx',
        'BUYBACK': 'confirm_buyback_tx'
      };
      var rpcName = rpcMap[currentPaymentData.type];

      var allItems = paymentItems.cash.concat(paymentItems.bank);
      var lakItems = allItems.filter(function(i) { return i.currency === 'LAK' && i.amount > 0; });
      var nonLakItems = allItems.filter(function(i) { return i.currency !== 'LAK' && i.amount > 0; });

      var paymentEntries = [];
      lakItems.forEach(function(i) { paymentEntries.push(i); });
      nonLakItems.forEach(function(i) { paymentEntries.push(i); });

      if (paymentEntries.length === 0) {
        alert('❌ ไม่มีรายการชำระเงิน');
        endSubmit();
        return;
      }

      var totalFee = 0;
      if (currentPaymentData.type === 'BUYBACK') {
        paymentItems.bank.forEach(function(item) { totalFee += item.fee || 0; });
      }

      for (var pi = 0; pi < paymentEntries.length; pi++) {
        var p = paymentEntries[pi];
        var bankId = null;
        if (p.bank) {
          try {
            var b = await dbSelect('banks', { select: 'id', filters: { name: 'eq.' + p.bank }, limit: 1, useCache: true });
            if (b && b.length > 0) bankId = b[0].id;
          } catch(e2) {}
        }

        var params = {
          p_tx_id: currentPaymentData.id,
          p_paid: p.amount,
          p_currency: p.currency,
          p_method: p.method,
          p_bank_id: bankId,
          p_change: pi === paymentEntries.length - 1 ? change : 0
        };
        if (currentPaymentData.type === 'BUYBACK') {
          params.p_fee = pi === 0 ? totalFee : 0;
        }

        var partial = await dbRpc(rpcName, params);
        if (!partial || !partial.success) {
          alert('❌ เกิดข้อผิดพลาด: ' + (partial && partial.message ? partial.message : 'Unknown'));
          endSubmit();
          return;
        }
      }

      showToast('✅ ยืนยันการชำระเงินสำเร็จ!');
      closeModal('multiPaymentModal');
      currentPaymentData = null;
      paymentItems = { cash: [], bank: [] };
      if (typeof loadSells === 'function') loadSells();
      if (typeof loadTradeins === 'function') loadTradeins();
      if (typeof loadExchanges === 'function') loadExchanges();
      if (typeof loadWithdraws === 'function') loadWithdraws();
      if (typeof loadBuybacks === 'function') loadBuybacks();
      endSubmit();
      return;
    }

    alert('❌ ไม่รองรับประเภทธุรกรรม: ' + currentPaymentData.type);
    endSubmit();
  } catch (error) {
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    endSubmit();
  }
}

async function openSellPayment(sellId) {
  try {
    var rows = await dbSelect('transactions', {
      select: '*,items:transaction_items(product_id,qty,item_role)',
      filters: { id: 'eq.' + sellId, type: 'eq.SELL' },
      useCache: false
    });
    if (!rows || rows.length === 0) return;
    var sell = rows[0];
    var newItems = (sell.items || []).filter(function(i) { return i.item_role === 'NEW'; })
      .map(function(i) { return { productId: i.product_id, qty: i.qty }; });
    var itemsJson = JSON.stringify(newItems);
    var items = formatItemsForPayment(itemsJson);
    var total = parseFloat(sell.total) || 0;
    openMultiPaymentModal('SELL', sellId, total, sell.phone, '<strong>Items:</strong> ' + items);
  } catch(e) {
    alert('Error: ' + e.message);
  }
}

async function _loadTxWithItems(txId) {
  var rows = await dbSelect('transactions', {
    select: '*,items:transaction_items(product_id,qty,item_role)',
    filters: { id: 'eq.' + txId },
    limit: 1,
    useCache: false
  });
  if (!rows || rows.length === 0) return null;
  var r = rows[0];
  var byRole = function(role) {
    return (r.items || []).filter(function(i) { return i.item_role === role; })
      .map(function(i) { return { productId: i.product_id, qty: parseFloat(i.qty) }; });
  };
  r._oldItems = byRole('OLD');
  r._newItems = byRole('NEW');
  r._focItems = byRole('FOC');
  r._switchItems = byRole('SWITCH');
  r._freeExItems = byRole('FREE_EX');
  return r;
}

async function openTradeinPaymentModal(tradeinId) {
  var r = await _loadTxWithItems(tradeinId);
  if (!r) return;
  var oldGold = formatItemsForPayment(JSON.stringify(r._oldItems.concat(r._focItems)));
  var newGold = formatItemsForPayment(JSON.stringify(r._newItems));
  var total = parseFloat(r.total) || 0;
  openMultiPaymentModal('TRADEIN', tradeinId, total, r.phone,
    '<strong>Old Gold:</strong> ' + oldGold + '<br><strong>New Gold:</strong> ' + newGold);
}

async function openExchangePaymentModal(exchangeId) {
  var r = await _loadTxWithItems(exchangeId);
  if (!r) return;
  var oldGold = formatItemsForPayment(JSON.stringify(r._oldItems.concat(r._switchItems).concat(r._freeExItems)));
  var newGold = formatItemsForPayment(JSON.stringify(r._newItems));
  var total = parseFloat(r.total) || 0;
  openMultiPaymentModal('EXCHANGE', exchangeId, total, r.phone,
    '<strong>Old Gold:</strong> ' + oldGold + '<br><strong>New Gold:</strong> ' + newGold);
}

async function openWithdrawPaymentModal(withdrawId) {
  var r = await _loadTxWithItems(withdrawId);
  if (!r) return;
  var items = formatItemsForPayment(JSON.stringify(r._newItems));
  var total = parseFloat(r.total) || 0;
  openMultiPaymentModal('WITHDRAW', withdrawId, total, r.phone, '<strong>Items:</strong> ' + items);
}

function formatItemsForPayment(itemsJson) {
  try {
    var items = typeof itemsJson === 'string' ? JSON.parse(itemsJson) : itemsJson;
    return items.map(function(item) {
      var product = FIXED_PRODUCTS.find(function(p) { return p.id === item.productId; });
      return (product ? product.name : item.productId) + ' x' + item.qty;
    }).join(', ');
  } catch (e) {
    return '-';
  }
}

async function openBuybackPaymentModalFromList(buybackId) {
  var r = await _loadTxWithItems(buybackId);
  if (!r) return;

  var total = parseFloat(r.price) || parseFloat(r.total) || 0;
  var paid = parseFloat(r.paid) || 0;
  var balance = parseFloat(r.balance);
  if (isNaN(balance)) balance = total - paid;
  var outstanding = balance > 0 ? balance : (total - paid);

  var itemsJson = JSON.stringify(r._oldItems);

  currentPaymentData = {
    type: 'BUYBACK',
    id: buybackId,
    total: outstanding,
    basePrice: total,
    paid: paid,
    phone: r.phone,
    items: itemsJson,
    details: '<strong>Items:</strong> ' + formatItemsForPayment(itemsJson) + '<br>' +
              '<strong>Buyback Price:</strong> ' + formatNumber(total) + ' LAK<br>' +
              '<strong>ยอดคงค้าง:</strong> ' + formatNumber(outstanding) + ' LAK',
    allowPartial: true
  };
  paymentItems = { cash: [], bank: [] };

  document.getElementById('multiPaymentTitle').textContent = 'Payment Confirmation (Buyback)';
  document.getElementById('multiPaymentId').textContent = buybackId;
  document.getElementById('multiPaymentPhone').textContent = r.phone;
  document.getElementById('multiPaymentDetails').innerHTML = currentPaymentData.details;
  document.getElementById('multiPaymentTotal').textContent = formatNumber(outstanding) + ' LAK';

  document.getElementById('multiPaymentFeeGroup').style.display = 'none';

  document.getElementById('cashPaymentsList').innerHTML = '';
  document.getElementById('bankPaymentsList').innerHTML = '';

  updatePaymentSummary();

  openModal('multiPaymentModal');
}

function onBuybackFeeChange() {
}
