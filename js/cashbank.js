var _cashbankAllRows = [];
var _cashbankFilteredTypes = ['CASH_IN', 'CASH_OUT', 'BANK_IN', 'BANK_OUT', 'BANK_DEPOSIT', 'BANK_WITHDRAW', 'OTHER_INCOME', 'OTHER_EXPENSE', 'OPEN_SHIFT', 'STOCK_IN', 'STOCK_IN_FEE'];
var _oeRatesTried = false;  // ลองโหลดเรทขาย (price_rates) ครั้งเดียวสำหรับ preview Other Expense

async function loadCashBank() {
  try {
    showLoading();

    var balResult = await dbRpc('get_cashbank_balances', {});

    var balances = {
      cash: { LAK: 0, THB: 0, USD: 0 },
      bcel: { LAK: 0, THB: 0, USD: 0 },
      ldb: { LAK: 0, THB: 0, USD: 0 },
      other: { LAK: 0, THB: 0, USD: 0 }
    };

    if (balResult && balResult.cash) {
      balances.cash.LAK = parseFloat(balResult.cash.LAK) || 0;
      balances.cash.THB = parseFloat(balResult.cash.THB) || 0;
      balances.cash.USD = parseFloat(balResult.cash.USD) || 0;
    }
    if (balResult && balResult.banks) {
      var banksKey = { 'BCEL': 'bcel', 'LDB': 'ldb', 'OTHER': 'other' };
      Object.keys(balResult.banks).forEach(function(bankName) {
        var key = banksKey[bankName] || 'other';
        var b = balResult.banks[bankName] || {};
        balances[key].LAK = parseFloat(b.LAK) || 0;
        balances[key].THB = parseFloat(b.THB) || 0;
        balances[key].USD = parseFloat(b.USD) || 0;
      });
    }

    document.getElementById('cashLAK').textContent = formatNumber(balances.cash.LAK);
    document.getElementById('cashTHB').textContent = formatCurrency(balances.cash.THB, 'THB');
    document.getElementById('cashUSD').textContent = formatCurrency(balances.cash.USD, 'USD');
    document.getElementById('bcelLAK').textContent = formatNumber(balances.bcel.LAK);
    document.getElementById('bcelTHB').textContent = formatCurrency(balances.bcel.THB, 'THB');
    document.getElementById('bcelUSD').textContent = formatCurrency(balances.bcel.USD, 'USD');
    document.getElementById('ldbLAK').textContent = formatNumber(balances.ldb.LAK);
    document.getElementById('ldbTHB').textContent = formatCurrency(balances.ldb.THB, 'THB');
    document.getElementById('ldbUSD').textContent = formatCurrency(balances.ldb.USD, 'USD');
    document.getElementById('otherBankLAK').textContent = formatNumber(balances.other.LAK);
    document.getElementById('otherBankTHB').textContent = formatCurrency(balances.other.THB, 'THB');
    document.getElementById('otherBankUSD').textContent = formatCurrency(balances.other.USD, 'USD');

    var rows = await dbSelect('cashbank', {
      select: 'id,type,amount,currency,rate,method,bank_id,note,date,ref_tx_id,bank:banks!bank_id(name)',
      filters: { type: 'in.(' + _cashbankFilteredTypes.join(',') + ')' },
      order: 'date.desc',
      limit: 500,
      useCache: false
    });

    _cashbankAllRows = (rows || []).map(function(r) {
      return [
        r.id,
        r.type,
        r.amount,
        r.currency,
        r.method,
        r.bank ? r.bank.name : '',
        r.note || '',
        r.date,
        r.ref_tx_id || '',
        parseFloat(r.rate) || 1
      ];
    });

    var cbStart = document.getElementById('cbStartDate');
    var cbEnd = document.getElementById('cbEndDate');
    if (!cbStart.value && !cbEnd.value) {
      var today = new Date();
      var todayStr = today.getFullYear() + '-' + String(today.getMonth() + 1).padStart(2, '0') + '-' + String(today.getDate()).padStart(2, '0');
      cbStart.value = todayStr;
      cbEnd.value = todayStr;
    }
    filterCashBankByDate();
    hideLoading();
  } catch (error) {
    console.error('Error loading cashbank:', error);
    hideLoading();
  }
}

function renderCashBankTable(rows) {
  var tbody = document.getElementById('cashbankTable');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" style="text-align: center; padding: 40px;">No records</td></tr>';
    return;
  }
  tbody.innerHTML = rows.map(function(row) {
    var amount = parseFloat(row[2]) || 0;
    var currency = row[3] || '-';
    var rate = parseFloat(row[9]) || 1;
    // เงินเข้า (IN) = บวก / เงินออก (OUT) = ลบ
    var isOut = amount < 0;
    var dirColor = isOut ? '#f44336' : '#4caf50';
    var dirLabel = isOut ? 'OUT ▼' : 'IN ▲';
    var sign = isOut ? '-' : '+';
    var absAmount = Math.abs(amount);
    var amountCell = '<span style="color:' + dirColor + ';font-weight:700;">' + sign + formatCurrency(absAmount, row[3]) + '</span>';
    // เก็บเป็นสกุลนั้นตรงๆ ไม่แปลงเป็น LAK (ไม่ใช้ rate)
    var typeCell = row[1] + ' <span style="background:' + dirColor + ';color:#fff;padding:1px 6px;border-radius:4px;font-size:10px;white-space:nowrap;">' + dirLabel + '</span>';
    // STOCK_IN: ดึง ref (SIN-...) จาก note หรือ ref_tx_id → ปุ่ม View ดูรายละเอียดการจ่าย
    var noteCell = (row[6] || '-');
    var type = row[1] || '';
    if (type === 'STOCK_IN' || type === 'STOCK_IN_FEE') {
      var note = row[6] || '';
      var m = note.match(/\[ref:([^\]]+)\]/);
      var ref = m ? m[1] : (row[8] || '');
      if (ref) {
        noteCell += ' <button class="btn-action" style="background:#555;padding:2px 8px;font-size:11px;" onclick="viewBillDetail(\'' + ref + '\',\'STOCK_IN\',\'NEW\')">👁 View</button>';
      }
    }
    return '<tr>' +
      '<td>' + row[0] + '</td>' +
      '<td style="white-space:nowrap;">' + typeCell + '</td>' +
      '<td>' + amountCell + '</td>' +
      '<td>' + currency + '</td>' +
      '<td>' + row[4] + '</td>' +
      '<td>' + (row[5] || '-') + '</td>' +
      '<td>' + noteCell + '</td>' +
      '<td>' + formatDateTime(row[7]) + '</td>' +
      '</tr>';
  }).join('');
}

function filterCashBankByDate() {
  var startStr = document.getElementById('cbStartDate').value;
  var endStr = document.getElementById('cbEndDate').value;
  if (!startStr && !endStr) {
    renderCashBankTable(_cashbankAllRows);
    return;
  }
  var startDate = startStr ? new Date(startStr + 'T00:00:00') : null;
  var endDate = endStr ? new Date(endStr + 'T23:59:59') : null;
  var filtered = _cashbankAllRows.filter(function(row) {
    var d = new Date(row[7]);
    if (isNaN(d.getTime())) return false;
    if (startDate && d < startDate) return false;
    if (endDate && d > endDate) return false;
    return true;
  });
  renderCashBankTable(filtered);
}

function showTodayCashBank() {
  var today = new Date();
  var todayStr = today.getFullYear() + '-' + String(today.getMonth() + 1).padStart(2, '0') + '-' + String(today.getDate()).padStart(2, '0');
  document.getElementById('cbStartDate').value = todayStr;
  document.getElementById('cbEndDate').value = todayStr;
  filterCashBankByDate();
}

function toggleOtherIncomeBank() {
  var method = document.getElementById('otherIncomeMethod').value;
  document.getElementById('otherIncomeBankGroup').style.display = method === 'BANK' ? 'block' : 'none';
}

function toggleOtherExpenseBank() {
  var method = document.getElementById('otherExpenseMethod').value;
  document.getElementById('otherExpenseBankGroup').style.display = method === 'BANK' ? 'block' : 'none';
}

function updateCashbankRate(prefix) {
  // เก็บเป็นสกุลนั้นตรงๆ ไม่ต้องกรอก rate → ซ่อนช่อง Rate เสมอ
  var rateGroup = document.getElementById(prefix + 'RateGroup');
  var rateEl = document.getElementById(prefix + 'Rate');
  if (rateGroup) rateGroup.style.display = 'none';
  if (rateEl) rateEl.value = '';
  // Other Expense ต้องเป็น LAK เสมอ — โชว์ตัวอย่างค่าที่จะถูกแปลงเป็น LAK (เรทขายล่าสุด)
  if (prefix === 'otherExpense') updateOtherExpenseLakPreview();
}

// แสดงตัวอย่างมูลค่า LAK ที่จะถูกบันทึก เมื่อ Other Expense กรอกเป็น THB/USD
// (การแปลงจริงทำที่ backend add_cashbank_entry ด้วยเรทขายล่าสุด ณ ตอนกดบันทึก)
function updateOtherExpenseLakPreview() {
  var el = document.getElementById('otherExpenseLakConv');
  if (!el) return;
  var cur = (document.getElementById('otherExpenseCurrency') || {}).value;
  var amtEl = document.getElementById('otherExpenseAmount');
  var amt = (amtEl && (amtEl.numericValue || parseFloat(String(amtEl.value).replace(/,/g, '')))) || 0;
  if (cur === 'LAK' || !amt) { el.style.display = 'none'; return; }
  var rates = (typeof currentPriceRates !== 'undefined' && currentPriceRates) ? currentPriceRates : {};
  var rate = parseFloat(cur === 'THB' ? rates.thbSell : rates.usdSell) || 0;
  // เรทยังไม่โหลด (ยังไม่เคยเปิดแท็บ Price Rate) → ลองดึงครั้งเดียวแล้ว render ใหม่
  if (!rate && !_oeRatesTried && typeof loadPriceRate === 'function') {
    _oeRatesTried = true;
    Promise.resolve(loadPriceRate()).then(function () { updateOtherExpenseLakPreview(); }).catch(function () {});
  }
  el.style.display = 'block';
  if (!rate) {
    el.style.color = '#f44336';
    el.innerHTML = '⚠️ ยังไม่มีเรทขาย ' + cur + '/LAK — โปรดตั้งเรทใน Price Rate ก่อนบันทึก';
    return;
  }
  el.style.color = 'var(--gold-primary)';
  el.innerHTML = '= ' + formatNumber(Math.round(amt * rate)) + ' LAK '
    + '<span style="font-weight:400;color:var(--text-secondary,#888);">(เรทขาย ' + cur + ' ล่าสุด ' + formatNumber(rate) + ')</span>';
}

function _readCashbankRate(prefix) {
  // ไม่ใช้ rate อีกต่อไป (เก็บตามสกุลเงินตรงๆ)
  return 1;
}

async function _submitCashBankEntry(type, amount, currency, method, bank, note, rate) {
  if (!amount || amount <= 0) {
    alert('Please enter amount');
    return false;
  }
  _isSubmitting = true;
  showLoading();
  try {
    var result = await dbRpc('add_cashbank_entry', {
      p_type: type,
      p_amount: amount,
      p_currency: currency,
      p_method: method,
      p_bank_name: bank || null,
      p_note: note,
      p_rate: currency === 'LAK' ? 1 : rate
    });
    hideLoading();
    if (result && result.success) {
      showToast('✅ Transaction added successfully!');
      return true;
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
      return false;
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
    return false;
  }
}

function _resetCashbankModal(prefix) {
  var amountEl = document.getElementById(prefix + 'Amount');
  var noteEl = document.getElementById(prefix + 'Note');
  var rateEl = document.getElementById(prefix + 'Rate');
  if (amountEl) amountEl.value = '';
  if (noteEl) noteEl.value = '';
  if (rateEl) rateEl.value = '';
  updateCashbankRate(prefix);
}

async function submitCash() {
  if (_isSubmitting) return;
  var type = document.getElementById('cashType').value;
  var amountEl = document.getElementById('cashAmount');
  var amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  var currency = document.getElementById('cashCurrency').value;
  var note = document.getElementById('cashNote').value;
  var rate = _readCashbankRate('cash');
  var dbType = type === 'IN' ? 'CASH_IN' : 'CASH_OUT';
  var ok = await _submitCashBankEntry(dbType, amount, currency, 'CASH', '', note, rate);
  if (ok) {
    closeModal('cashModal');
    _resetCashbankModal('cash');
    loadCashBank();
  }
}

async function submitBank() {
  if (_isSubmitting) return;
  var type = document.getElementById('bankType').value;
  var bank = document.getElementById('bankName').value;
  var amountEl = document.getElementById('bankAmount');
  var amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  var currency = document.getElementById('bankCurrency').value;
  var note = document.getElementById('bankNote').value;
  var rate = _readCashbankRate('bank');
  var dbType = type === 'DEPOSIT' ? 'BANK_DEPOSIT' : 'BANK_WITHDRAW';
  var ok = await _submitCashBankEntry(dbType, amount, currency, 'BANK', bank, note, rate);
  if (ok) {
    closeModal('bankModal');
    _resetCashbankModal('bank');
    loadCashBank();
  }
}

async function submitOtherIncome() {
  if (_isSubmitting) return;
  var method = document.getElementById('otherIncomeMethod').value;
  var bank = method === 'BANK' ? document.getElementById('otherIncomeBank').value : '';
  var amountEl = document.getElementById('otherIncomeAmount');
  var amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  var currency = document.getElementById('otherIncomeCurrency').value;
  var note = document.getElementById('otherIncomeNote').value;
  var rate = _readCashbankRate('otherIncome');
  var ok = await _submitCashBankEntry('OTHER_INCOME', amount, currency, method, bank, note, rate);
  if (ok) {
    closeModal('otherIncomeModal');
    _resetCashbankModal('otherIncome');
    loadCashBank();
  }
}

async function submitOtherExpense() {
  if (_isSubmitting) return;
  var method = document.getElementById('otherExpenseMethod').value;
  var bank = method === 'BANK' ? document.getElementById('otherExpenseBank').value : '';
  var amountEl = document.getElementById('otherExpenseAmount');
  var amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  var currency = document.getElementById('otherExpenseCurrency').value;
  var note = document.getElementById('otherExpenseNote').value;
  var rate = _readCashbankRate('otherExpense');
  var ok = await _submitCashBankEntry('OTHER_EXPENSE', amount, currency, method, bank, note, rate);
  if (ok) {
    closeModal('otherExpenseModal');
    _resetCashbankModal('otherExpense');
    loadCashBank();
  }
}
