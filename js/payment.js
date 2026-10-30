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
  _setPaymentEditMode(false);

  updatePaymentSummary();
  
  openModal('multiPaymentModal');
}

// เรทแปลงเป็น LAK: Buyback (ร้านจ่ายออก) ใช้เรทรับซื้อ, อื่น ๆ ใช้เรทขาย
function _paymentRateFor(currency, type) {
  if (currency === 'LAK') return 1;
  var isBuy = type === 'BUYBACK';
  if (currency === 'THB') return (isBuy ? currentExchangeRates?.THB_Buy : currentExchangeRates?.THB_Sell) || 0;
  return (isBuy ? currentExchangeRates?.USD_Buy : currentExchangeRates?.USD_Sell) || 0;
}

function addCashPayment() {
  const id = Date.now();
  paymentItems.cash.push({ id, method: 'CASH', currency: 'LAK', amount: 0, rate: 1 });
  renderCashPayments();
}

function addBankPayment() {
  const id = Date.now();
  paymentItems.bank.push({ id, method: 'BANK', bank: 'BCEL', currency: 'LAK', amount: 0, rate: 1 });
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
  container.innerHTML = paymentItems.bank.map((item, idx) => {
    const lakAmount = item.amount * item.rate;
    return `
    <div class="payment-item" data-id="${item.id}" style="margin-bottom: 10px; padding: 12px; background: var(--bg-light); border-radius: 8px;">
      <div style="display: flex; gap: 10px; align-items: center; margin-bottom: 8px;">
        <select class="form-select" style="flex: 1;" onchange="updateBankName(${item.id}, this.value)">
          <option value="BCEL" ${item.bank === 'BCEL' ? 'selected' : ''}>BCEL</option>
          <option value="LDB" ${item.bank === 'LDB' ? 'selected' : ''}>LDB</option>
          <option value="OTHER" ${item.bank === 'OTHER' ? 'selected' : ''}>อื่น ๆ</option>
          ${item.bank && ['BCEL', 'LDB', 'OTHER'].indexOf(item.bank) === -1 ? `<option value="${item.bank}" selected>${item.bank}</option>` : ''}
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
    item.rate = _paymentRateFor(value, currentPaymentData?.type);
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
    item.rate = _paymentRateFor(value, currentPaymentData?.type);
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

  changeBox.style.display = isBuyback ? 'none' : '';
  
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
      var ch = roundChangeLak(Math.max(0, change));
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
    // [R19-3] แก้บิลที่จบแล้ว ต้องจ่ายครบ (ขาดได้ไม่เกิน 500 LAK)
    if (currentPaymentData.editMode && total - totalPaid > 500) {
      alert('❌ ยอดจ่ายยังไม่ครบ! ขาดอีก ' + formatNumber(Math.round(total - totalPaid)) + ' LAK');
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
    change = roundChangeLak(Math.max(0, totalPaid - total));
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

    // [R19-3] โหมดแก้บิล: เงินทอนลงบัญชีของเจ้าของบิล (server เช็คยอดเอง) ไม่ใช่กระเป๋าคนที่กดแก้
    if (!currentPaymentData.editMode) try {
      var userRows = await dbSelect('user_cashbook', {
        select: 'amount',
        filters: {
          user_id: 'eq.' + currentUser.id,
          currency: 'eq.LAK',
          bank_id: 'is.null'
        },
        useCache: false
      });
      var userCashLAK = (userRows || []).reduce(function(s, r) { return s + (parseFloat(r.amount) || 0); }, 0);
      if (userCashLAK < change) {
        alert('❌ เงินสด LAK ของคุณไม่พอทอน! มี ' + formatNumber(userCashLAK) + ' LAK แต่ต้องทอน ' + formatNumber(change) + ' LAK');
        _isSubmitting = false;
        hideLoading();
        return;
      }
    } catch(e) {
      console.error('Error checking cash balance:', e);
      alert('❌ ไม่สามารถตรวจสอบยอดเงินได้: ' + e.message);
      _isSubmitting = false;
      hideLoading();
      return;
    }
  }

  try {
    showLoading();

    if (currentPaymentData.editMode) {
      await submitPaymentEdit(change);
      return;
    }

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

      // [R14] บิลที่ยอดรวม = 0 (เช่น Free Exchange / เปลี่ยนฟรี) ยืนยันได้เลย
      //   ขอแค่ Remaining = 0 ก็พอ ไม่ต้องเพิ่มรายการชำระเงิน
      if (paymentEntries.length === 0 && total > 0) {
        alert('❌ ไม่มีรายการชำระเงิน');
        endSubmit();
        return;
      }

      if (currentPaymentData.type === 'BUYBACK') {
        // [R19-1] ยอดค้าง ≤ 500 LAK (ทุกสกุล รวม LAK) → รายการสุดท้ายปิดบิลตาม Total
        // [R20-1] จ่ายทุกรายการใน RPC เดียว — รายการไหน error = ยกเลิกทั้งรอบ (เดิมรายการแรกค้างในบิล)
        var allowShort = (total - totalPaid) <= 500;
        var bbRes = await dbRpc('confirm_buyback_multi_tx', {
          p_tx_id: currentPaymentData.id,
          p_payments: paymentEntries.map(function(p) {
            return { method: p.method, currency: p.currency, amount: p.amount, bank: p.bank || '' };
          }),
          p_allow_short: allowShort
        });
        if (!bbRes || !bbRes.success) {
          alert('❌ เกิดข้อผิดพลาด: ' + (bbRes && bbRes.message ? bbRes.message : 'Unknown'));
          endSubmit();
          return;
        }
      } else {
        var payments = paymentEntries.map(function(p) {
          return {
            method: p.method,
            currency: p.currency,
            amount: p.amount,
            rate: p.rate || 1,
            bank: p.bank || ''
          };
        });

        var res = await dbRpc(rpcName, {
          p_tx_id: currentPaymentData.id,
          p_payments: payments,
          p_change: change
        });
        if (!res || !res.success) {
          alert('❌ เกิดข้อผิดพลาด: ' + (res && res.message ? res.message : 'Unknown'));
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

  document.getElementById('cashPaymentsList').innerHTML = '';
  document.getElementById('bankPaymentsList').innerHTML = '';
  _setPaymentEditMode(false);

  updatePaymentSummary();

  openModal('multiPaymentModal');
}

function onBuybackFeeChange() {
}

// ============================================================
// [R19-3] แก้ไขการชำระเงินบิลที่จบแล้ว (Admin เท่านั้น — R20-2) — ใช้ modal เดียวกับตอนรับ/จ่ายเงิน
//   server (edit_tx_payments) ลงส่วนต่าง: กะ Sales ยังไม่ปิด → กระเป๋า Sales ; ปิดแล้ว/Manager รับ → เงินร้าน
// ============================================================
function _setPaymentEditMode(on) {
  var grp = document.getElementById('multiPaymentEditReasonGroup');
  var inp = document.getElementById('multiPaymentEditReason');
  if (grp) grp.style.display = on ? '' : 'none';
  if (inp) inp.value = '';
}

async function openEditPaymentModal(txId) {
  if (!isAdmin()) return;
  var info;
  try {
    showLoading();
    info = await dbRpc('get_tx_payment_edit_info', { p_tx_id: txId });
  } catch (e) {
    hideLoading();
    alert('❌ เกิดข้อผิดพลาด: ' + e.message);
    return;
  }
  hideLoading();
  if (!info || !info.success) {
    alert(info && info.message ? info.message : '❌ เกิดข้อผิดพลาด');
    return;
  }

  var type = info.type;
  var total = parseFloat(info.total) || 0;
  var led = info.ledger || {};
  var who = led.nickname || 'Sales';
  var ledgerText = led.mode === 'SHIFT'
    ? '🟢 กะของ ' + who + ' ยังไม่ปิด → ปรับยอดในกระเป๋า ' + who + ' (เงินโอนปรับที่บัญชีร้าน)'
    : '🏦 ' + (led.nickname ? 'กะของ ' + led.nickname + ' ปิดแล้ว' : 'Manager/Admin เป็นผู้รับ/จ่ายเงิน') + ' → ปรับยอดเงินร้าน';

  var details = '<div style="padding:8px 10px;border-radius:6px;background:rgba(255,152,0,0.12);border:1px solid #ff9800;font-size:13px;">' + ledgerText + '</div>';
  var oldChange = parseFloat(info.change) || 0;
  if (oldChange > 0) details += '<div style="margin-top:6px;font-size:12px;color:var(--text-secondary);">เงินทอนเดิม: ' + formatNumber(oldChange) + ' LAK</div>';
  var payments = info.payments || [];
  if (payments.some(function(p) { return p.currency && p.currency !== 'LAK'; })) {
    details += '<div style="margin-top:6px;font-size:11px;color:var(--text-secondary);">* รายการ THB/USD คิดเป็น LAK ด้วยเรทปัจจุบัน</div>';
  }
  (info.edits || []).forEach(function(e) {
    details += '<div style="margin-top:4px;font-size:11px;color:var(--text-secondary);">✏️ แก้ไขเมื่อ ' + formatDateTime(e.edited_at) + ' โดย ' + (e.by || '-') + ': ' + (e.reason || '') + '</div>';
  });

  openMultiPaymentModal(type, txId, total, info.phone, details);
  document.getElementById('multiPaymentTitle').textContent = '✏️ แก้ไขการชำระเงิน';
  currentPaymentData.editMode = true;
  _setPaymentEditMode(true);

  var seq = Date.now();
  payments.forEach(function(p) {
    var cur = p.currency || 'LAK';
    var item = { id: seq++, currency: cur, amount: parseFloat(p.amount) || 0, rate: _paymentRateFor(cur, type) };
    if (String(p.method || '').toUpperCase() === 'CASH') {
      item.method = 'CASH';
      paymentItems.cash.push(item);
    } else {
      item.method = 'BANK';
      item.bank = p.bank || 'OTHER';
      paymentItems.bank.push(item);
    }
  });
  renderCashPayments();
  renderBankPayments();
}

async function submitPaymentEdit(change) {
  var reasonEl = document.getElementById('multiPaymentEditReason');
  var reason = reasonEl ? reasonEl.value.trim() : '';
  if (!reason) {
    alert('❌ กรุณาระบุเหตุผลที่แก้ไข');
    endSubmit();
    return;
  }

  var payments = paymentItems.cash.concat(paymentItems.bank)
    .filter(function(p) { return p.amount > 0; })
    .map(function(p) {
      return { method: p.method, currency: p.currency, amount: p.amount, rate: p.rate || 1, bank: p.bank || '' };
    });

  var res = await dbRpc('edit_tx_payments', {
    p_tx_id: currentPaymentData.id,
    p_payments: payments,
    p_change: currentPaymentData.type === 'BUYBACK' ? 0 : change,
    p_reason: reason
  });
  if (!res || !res.success) {
    alert(res && res.message ? res.message : '❌ เกิดข้อผิดพลาด');
    endSubmit();
    return;
  }

  showToast('✅ แก้ไขการชำระเงินสำเร็จ');
  closeModal('multiPaymentModal');
  currentPaymentData = null;
  paymentItems = { cash: [], bank: [] };
  if (typeof loadHistorySell === 'function') loadHistorySell();
  if (typeof loadBuybacks === 'function') loadBuybacks();
  endSubmit();
}

// ============================================================
// [R19-4] กดแก้ไขบิล → เลือก "แก้ยอดเงิน" หรือ "แก้ยอดทอง"
//   แก้ทอง: เปลี่ยนชนิด/จำนวนแท่งได้ แต่น้ำหนักรวมแต่ละกลุ่มต้องเท่าเดิม (เงินของบิลไม่เปลี่ยน)
// ============================================================
var _txEditChooserId = null;
var _goldEdit = null;
var GOLD_EDIT_ROLE_LABELS = {
  'NEW': 'ทองใหม่ (ออกจากร้าน)',
  'OLD': 'ทองเก่า (รับเข้า)',
  'FOC': 'F.O.C (ทองเก่า)',
  'SWITCH': 'Switch (ทองเก่า)',
  'FREE_EX': 'Free Ex (ทองเก่า)'
};
var GOLD_EDIT_ROLE_ORDER = ['NEW', 'OLD', 'FOC', 'SWITCH', 'FREE_EX'];

function openTxEditChooser(txId) {
  if (!isAdmin()) return;
  _txEditChooserId = txId;
  document.getElementById('txEditChooserId').textContent = txId;
  openModal('txEditChooserModal');
}

function chooseTxEdit(kind) {
  var id = _txEditChooserId;
  closeModal('txEditChooserModal');
  if (!id) return;
  if (kind === 'gold') openEditGoldModal(id);
  else openEditPaymentModal(id);
}

function _goldEditGramsPerUnit(pid) {
  var p = FIXED_PRODUCTS.find(function(x) { return x.id === pid; });
  return p ? Math.round(p.weight * 15 * 1000) / 1000 : 0;
}

function _goldEditGrams(map) {
  var g = 0;
  Object.keys(map || {}).forEach(function(pid) { g += (parseFloat(map[pid]) || 0) * _goldEditGramsPerUnit(pid); });
  return Math.round(g * 1000) / 1000;
}

async function openEditGoldModal(txId) {
  if (!isAdmin()) return;
  var info;
  try {
    showLoading();
    info = await dbRpc('get_tx_gold_edit_info', { p_tx_id: txId });
  } catch (e) {
    hideLoading();
    alert('❌ เกิดข้อผิดพลาด: ' + e.message);
    return;
  }
  hideLoading();
  if (!info || !info.success) {
    alert(info && info.message ? info.message : '❌ เกิดข้อผิดพลาด');
    return;
  }

  var orig = {};
  (info.items || []).forEach(function(i) {
    var role = String(i.role || '').toUpperCase();
    if (!orig[role]) orig[role] = {};
    orig[role][i.productId] = (orig[role][i.productId] || 0) + (parseFloat(i.qty) || 0);
  });
  var roles = GOLD_EDIT_ROLE_ORDER.filter(function(r) { return orig[r]; });
  if (roles.length === 0) {
    alert('❌ บิลนี้ไม่มีรายการทอง');
    return;
  }
  var cur = {};
  roles.forEach(function(r) {
    cur[r] = {};
    FIXED_PRODUCTS.forEach(function(p) { cur[r][p.id] = orig[r][p.id] || 0; });
  });
  _goldEdit = { id: txId, type: info.type, roles: roles, orig: orig, cur: cur };

  document.getElementById('goldEditId').textContent = txId;
  document.getElementById('goldEditPhone').textContent = info.phone || '-';
  document.getElementById('goldEditReason').value = '';

  var og = info.old_gold || {};
  var note = '<div style="padding:8px 10px;border-radius:6px;background:rgba(255,152,0,0.12);border:1px solid #ff9800;font-size:13px;margin-bottom:12px;">'
    + '⚖️ เปลี่ยนชนิด/จำนวนได้ แต่ <b>น้ำหนักรวมแต่ละกลุ่มต้องเท่าเดิม</b> — ยอดเงินของบิลไม่เปลี่ยน';
  if (og.state === 'HELD') note += '<br>🟢 ทองเก่ายังอยู่กับ ' + (og.nickname || 'Sales') + ' (กะยังไม่ปิด) → ปรับรายการที่ Sales ถือ';
  else if (og.state === 'STOCK') note += '<br>🏦 ทองเก่าเข้า Stock OLD แล้ว → ปรับ Stock OLD (ชิ้นเดิมต้องยังอยู่ในสต๊อก)';
  if (roles.indexOf('NEW') !== -1) note += '<br>📦 ทองใหม่ → คืนสต๊อก NEW ชิ้นเดิม แล้วตัดชิ้นใหม่';
  note += '</div>';
  (info.edits || []).forEach(function(e) {
    note += '<div style="margin:-6px 0 10px;font-size:11px;color:var(--text-secondary);">✏️ แก้ทองเมื่อ ' + formatDateTime(e.edited_at) + ' โดย ' + (e.by || '-') + ': ' + (e.reason || '') + '</div>';
  });
  document.getElementById('goldEditNote').innerHTML = note;

  renderGoldEdit();
  openModal('goldEditModal');
}

function renderGoldEdit() {
  if (!_goldEdit) return;
  var html = '';
  _goldEdit.roles.forEach(function(role) {
    html += '<div style="background:var(--bg-light);border-radius:8px;padding:12px;margin-bottom:12px;">';
    html += '<div style="font-weight:700;color:var(--gold-primary);margin-bottom:10px;">' + (GOLD_EDIT_ROLE_LABELS[role] || role) + '</div>';
    html += '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:8px;">';
    FIXED_PRODUCTS.forEach(function(p) {
      var q = _goldEdit.cur[role][p.id] || 0;
      var was = _goldEdit.orig[role][p.id] || 0;
      html += '<label style="display:block;font-size:12px;color:var(--text-secondary);">' + p.name
        + (was ? ' <span style="color:var(--gold-primary);">(เดิม ' + was + ')</span>' : '')
        + '<input type="number" min="0" step="1" class="form-input" style="margin-top:4px;" value="' + (q || '') + '" placeholder="0"'
        + ' oninput="updateGoldEditQty(\'' + role + '\',\'' + p.id + '\',this.value)"></label>';
    });
    html += '</div>';
    html += '<div id="goldEditSum_' + role + '" style="margin-top:10px;font-size:13px;font-weight:700;"></div>';
    html += '</div>';
  });
  document.getElementById('goldEditBody').innerHTML = html;
  _goldEdit.roles.forEach(updateGoldEditSummary);
}

function updateGoldEditQty(role, pid, value) {
  if (!_goldEdit || !_goldEdit.cur[role]) return;
  var n = parseFloat(String(value).replace(/,/g, ''));
  _goldEdit.cur[role][pid] = isNaN(n) ? 0 : n;
  updateGoldEditSummary(role);
}

function updateGoldEditSummary(role) {
  var el = document.getElementById('goldEditSum_' + role);
  if (!el || !_goldEdit) return;
  var oldG = _goldEditGrams(_goldEdit.orig[role]);
  var newG = _goldEditGrams(_goldEdit.cur[role]);
  var ok = Math.abs(oldG - newG) < 0.001;
  el.style.color = ok ? '#4caf50' : '#f44336';
  el.textContent = (ok ? '✓ ' : '✕ ') + 'น้ำหนักเดิม ' + oldG.toFixed(2) + ' g → ใหม่ ' + newG.toFixed(2) + ' g'
    + (ok ? '' : ' (ต่างกัน ' + (newG - oldG > 0 ? '+' : '') + (newG - oldG).toFixed(2) + ' g)');
}

async function submitGoldEdit() {
  if (_isSubmitting || !_goldEdit) return;

  var items = [];
  var bad = [];
  var changed = false;
  for (var ri = 0; ri < _goldEdit.roles.length; ri++) {
    var role = _goldEdit.roles[ri];
    var map = _goldEdit.cur[role];
    if (Math.abs(_goldEditGrams(_goldEdit.orig[role]) - _goldEditGrams(map)) >= 0.001) bad.push(GOLD_EDIT_ROLE_LABELS[role] || role);
    for (var pid in map) {
      var q = map[pid] || 0;
      if (q < 0 || Math.floor(q) !== q) { alert('❌ จำนวนต้องเป็นจำนวนเต็มบวก'); return; }
      if (q !== (_goldEdit.orig[role][pid] || 0)) changed = true;
      if (q > 0) items.push({ role: role, productId: pid, qty: q });
    }
  }
  if (bad.length) { alert('❌ น้ำหนักรวมต้องเท่าเดิม: ' + bad.join(', ')); return; }
  if (!changed) { alert('ไม่มีรายการที่เปลี่ยน'); return; }
  var reason = document.getElementById('goldEditReason').value.trim();
  if (!reason) { alert('❌ กรุณาระบุเหตุผลที่แก้ไข'); return; }

  _isSubmitting = true;
  try {
    showLoading();
    var res = await dbRpc('edit_tx_gold', { p_tx_id: _goldEdit.id, p_items: items, p_reason: reason });
    if (!res || !res.success) {
      alert(res && res.message ? res.message : '❌ เกิดข้อผิดพลาด');
      endSubmit();
      return;
    }
    showToast('✅ แก้ไขรายการทองสำเร็จ');
    closeModal('goldEditModal');
    _goldEdit = null;
    if (typeof loadHistorySell === 'function') loadHistorySell();
    if (typeof loadBuybacks === 'function') loadBuybacks();
    endSubmit();
  } catch (e) {
    alert('❌ เกิดข้อผิดพลาด: ' + e.message);
    endSubmit();
  }
}
