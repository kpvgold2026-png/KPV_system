async function loadSells() {
  try {
    var tbody = document.getElementById('sellTable');
    tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';

    var filters = { type: 'eq.SELL' };
    var order = sellSortOrder === 'asc' ? 'date.asc' : 'date.desc';

    if (currentUser.role === 'User') {
      filters.sale_user_id = 'eq.' + currentUser.id;
    }

    var dateFrom = sellDateFrom;
    var dateTo = sellDateTo;
    if (!dateFrom && !dateTo && (currentUser.role === 'User' || isManager())) {
      var today = getTodayLocalStr();
      dateFrom = today;
      dateTo = today;
    }
    if (dateFrom) filters['date'] = 'gte.' + dateFrom + 'T00:00:00';
    if (dateTo) {
      var existing = filters['date'];
      filters['and'] = '(date.gte.' + dateFrom + 'T00:00:00,date.lte.' + dateTo + 'T23:59:59)';
      delete filters['date'];
    }

    var rows = await dbSelect('transactions', {
      select: '*,items:transaction_items(product_id,qty,item_role),sale:users!sale_user_id(nickname)',
      filters: filters,
      order: order,
      useCache: false
    });

    var data = (rows || []).map(function(r) {
      var newItems = (r.items || []).filter(function(i) { return i.item_role === 'NEW'; })
        .map(function(i) { return { productId: i.product_id, qty: i.qty }; });
      return Object.assign({}, r, {
        _items: newItems,
        _itemsJson: JSON.stringify(newItems),
        _saleName: r.sale ? r.sale.nickname : ''
      });
    });

    if (data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="8" style="text-align: center; padding: 40px;">No records</td></tr>';
      return;
    }

    tbody.innerHTML = data.map(function(row) {
      var items = formatItemsForTable(row._itemsJson);
      var premium = parseFloat(row.premium) || calculatePremiumFromItems(row._itemsJson);
      var saleName = row._saleName;
      var status = row.status;
      var actions = '';

      if (status === 'PENDING') {
        if (isManager()) {
          actions = '<button class="btn-action" onclick="reviewSell(\'' + row.id + '\')">Review</button>';
        } else {
          actions = '<span style="color: var(--text-secondary);">Waiting for review</span>';
        }
      } else if (status === 'APPROVED' || status === 'READY') {
        if (currentUser.role === 'User') {
          actions = '<button class="btn-action" onclick="openSellPayment(\'' + row.id + '\')">Confirm</button>';
        } else {
          actions = '<span style="color: var(--text-secondary);">Waiting for confirmation</span>';
        }
      } else {
        var paid = parseFloat(row.paid) || 0;
        var changeLak = parseFloat(row.change_amount) || 0;
        var payInfo = paid > 0 ? formatNumber(paid) + ' ' + (row.currency || 'LAK') : '-';
        var detail = encodeURIComponent(JSON.stringify([
          ['Transaction ID', row.id],
          ['BILL ID', row.bill_id || '-'],
          ['Phone', row.phone],
          ['Items', formatItemsForTable(row._itemsJson)],
          ['Total', formatNumber(row.total) + ' LAK'],
          ['Customer Paid', payInfo],
          ['Change', changeLak > 0 ? formatNumber(changeLak) + ' LAK' : '-'],
          ['Date', formatDateTime(row.date)],
          ['Status', status],
          ['Sale', saleName]
        ]));
        actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Sell\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
      }

      return '<tr>' +
        '<td>' + row.id + '</td>' +
        '<td>' + (row.bill_id || '-') + '</td>' +
        '<td style="font-size:11px;white-space:nowrap;">' + (row.date ? formatDateTime(row.date) : '') + '</td>' +
        '<td>' + row.phone + '</td>' +
        '<td>' + items + '</td>' +
        '<td>' + formatNumber(premium) + '</td>' +
        '<td>' + formatNumber(row.total) + '</td>' +
        '<td><span class="status-badge status-' + status.toLowerCase() + '">' + status + '</span></td>' +
        '<td>' + saleName + '</td>' +
        '<td>' + actions + '</td>' +
        '</tr>';
    }).join('');
  } catch (error) {
    console.error('Error loading sells:', error);
    var tbody = document.getElementById('sellTable');
    if (tbody) tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:40px;color:#f44336;">Error loading data</td></tr>';
  }
}

let sellCounter = 0;

function addSellProduct() {
  sellCounter++;
  const container = document.getElementById('sellProducts');
  const row = document.createElement('div');
  row.className = 'product-row';
  row.id = 'sellProduct' + sellCounter;
  row.innerHTML =
    '<select class="form-select" onchange="calculateSellTotal()">' +
      '<option value="">เลือกสินค้า...</option>' +
      FIXED_PRODUCTS.map(function(p) { return '<option value="' + p.id + '">' + p.name + '</option>'; }).join('') +
    '</select>' +
    '<input type="number" class="form-input" placeholder="จำนวน" min="1" step="1" oninput="calculateSellTotal()">' +
    '<button type="button" class="btn-remove" onclick="removeSellProduct(' + sellCounter + ')">×</button>';
  container.appendChild(row);
}

function removeSellProduct(id) {
  const row = document.getElementById('sellProduct' + id);
  if (row) {
    row.remove();
    calculateSellTotal();
  }
}

async function submitSell() {
  if (_isSubmitting) return;
  var phone = document.getElementById('sellPhone').value.replace(/\D/g, '');
  if (!phone || phone.length !== 8) {
    alert('กรุณากรอกเบอร์โทร 8 หลัก');
    return;
  }
  var billId = document.getElementById('sellBillId').value.replace(/\D/g, '');
  if (!billId || billId.length !== 6) {
    alert('กรุณากรอก BILL ID ตัวเลข 6 หลัก');
    return;
  }

  var items = [];
  document.querySelectorAll('#sellProducts .product-row').forEach(function(row) {
    var productId = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) {
      items.push({ productId: productId, qty: qty });
    }
  });

  if (items.length === 0) {
    alert('กรุณาเลือกสินค้าอย่างน้อย 1 รายการ');
    return;
  }

  _isSubmitting = true;
  showLoading();

  var totalPrice = 0;
  var totalPremium = 0;

  items.forEach(function(item) {
    var pricePerPiece = calculateSellPrice(item.productId, currentPricing.sell1Baht);
    totalPrice += pricePerPiece * item.qty;
    if (PREMIUM_PRODUCTS.includes(item.productId)) {
      totalPremium += PREMIUM_PER_PIECE * item.qty;
    }
  });

  totalPrice = roundTo1000(totalPrice + totalPremium);

  try {
    var merged = mergeItems(items);
    var result = await dbRpc('create_sell_tx', {
      p_phone: phone,
      p_bill_id: billId,
      p_items: merged,
      p_total: totalPrice,
      p_premium: totalPremium,
      p_sell_1baht: currentPricing.sell1Baht
    });

    if (result && result.success) {
      endSubmit();
      showToast('✅ สร้างรายการขายสำเร็จ!');
      try { if (billId) await dbRpc('check_duplicate_bill_id', { p_bill_id: billId }); } catch(e) {}
      closeModal('sellModal');
      document.getElementById('sellPhone').value = '';
      document.getElementById('sellBillId').value = '';
      document.getElementById('sellProducts').innerHTML = '';
      sellCounter = 0;
      addSellProduct();
      loadSells();
    } else {
      alert('❌ เกิดข้อผิดพลาด: ' + (result && result.message ? result.message : 'Unknown'));
      endSubmit();
    }
  } catch (error) {
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    endSubmit();
  }
}

async function checkStock(productId, requiredQty) {
  const currentStock = await getCurrentStock(productId);
  return currentStock >= requiredQty;
}

async function getCurrentStock(productId) {
  try {
    var rows = await dbSelect('stock_balances', {
      select: 'qty',
      filters: {
        product_id: 'eq.' + productId,
        gold_type: 'eq.NEW'
      },
      useCache: false
    });
    if (!rows || rows.length === 0) return 0;
    return parseFloat(rows[0].qty) || 0;
  } catch(e) {
    return 0;
  }
}

function viewSellDetails(sellId) {
  alert('View details for ' + sellId + ' (Manager view only)');
}

async function reviewSell(sellId) {
  if (!confirm('Approve this sell transaction?')) return;
  try {
    showLoading();
    const result = await dbRpc('review_sell_tx', { p_tx_id: sellId });
    hideLoading();
    if (result && result.success) {
      showToast('✅ Transaction reviewed and ready for confirmation!');
      loadSells();
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

function calculateSellTotal() {
  let totalPrice = 0;
  let totalPremium = 0;

  document.querySelectorAll('#sellProducts .product-row').forEach(function(row) {
    const productId = row.querySelector('select').value;
    const qty = parseInt(row.querySelector('input').value) || 0;

    if (productId && qty > 0) {
      const pricePerPiece = calculateSellPrice(productId, currentPricing.sell1Baht);
      const lineTotal = pricePerPiece * qty;
      totalPrice += lineTotal;
      if (PREMIUM_PRODUCTS.includes(productId)) {
        totalPremium += PREMIUM_PER_PIECE * qty;
      }
    }
  });

  const finalTotal = roundTo1000(totalPrice + totalPremium);
  const priceElement = document.getElementById('sellPrice');
  if (priceElement) {
    priceElement.value = formatNumber(finalTotal) + ' LAK';
    priceElement.dataset.rawValue = finalTotal;
  }
}

async function openSellModal() {
  if (currentPricing.sell1Baht === 0) {
    showLoading();
    await fetchCurrentPricing();
    hideLoading();
  }

  if (currentPricing.sell1Baht === 0) {
    alert('กรุณากำหนดราคาก่อนใช้งาน (Products → Set Pricing)');
    return;
  }

  openModal('sellModal');

  if (document.querySelectorAll('#sellProducts .product-row').length === 0) {
    addSellProduct();
  }
}

function resetSellDateFilter() {
  const today = getTodayDateString();
  document.getElementById('sellDateFrom').value = today;
  document.getElementById('sellDateTo').value = today;
  sellDateFrom = today;
  sellDateTo = today;
  loadSells();
}

document.addEventListener('DOMContentLoaded', function() {
  const fromInput = document.getElementById('sellDateFrom');
  const toInput = document.getElementById('sellDateTo');

  if (fromInput && toInput) {
    fromInput.addEventListener('change', function() {
      sellDateFrom = this.value;
      if (sellDateFrom && !sellDateTo) { sellDateTo = sellDateFrom; toInput.value = sellDateTo; }
      if (sellDateFrom && sellDateTo) loadSells();
    });

    toInput.addEventListener('change', function() {
      sellDateTo = this.value;
      if (sellDateTo && !sellDateFrom) { sellDateFrom = sellDateTo; fromInput.value = sellDateFrom; }
      if (sellDateFrom && sellDateTo) loadSells();
    });
  }
});
