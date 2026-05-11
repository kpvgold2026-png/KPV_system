async function loadBuybacks() {
  try {
    var tbody = document.getElementById('buybackTable');
    tbody.innerHTML = '<tr><td colspan="10" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';

    var filters = { type: 'eq.BUYBACK' };
    var order = buybackSortOrder === 'asc' ? 'date.asc' : 'date.desc';

    if (currentUser.role === 'User') {
      filters.sale_user_id = 'eq.' + currentUser.id;
    }

    var dateFrom = buybackDateFrom;
    var dateTo = buybackDateTo;
    if (!dateFrom && !dateTo && (currentUser.role === 'User' || isManager())) {
      var today = getTodayLocalStr();
      dateFrom = today;
      dateTo = today;
    }
    if (dateFrom && dateTo) {
      filters['and'] = '(date.gte.' + dateFrom + 'T00:00:00,date.lte.' + dateTo + 'T23:59:59)';
    } else if (dateFrom) {
      filters['date'] = 'gte.' + dateFrom + 'T00:00:00';
    }

    var rows = await dbSelect('transactions', {
      select: '*,items:transaction_items(product_id,qty,item_role),sale:users!sale_user_id(nickname)',
      filters: filters,
      order: order,
      useCache: false
    });

    var data = (rows || []).map(function(r) {
      var oldItems = (r.items || []).filter(function(i) { return i.item_role === 'OLD'; })
        .map(function(i) { return { productId: i.product_id, qty: i.qty }; });
      return Object.assign({}, r, {
        _itemsJson: JSON.stringify(oldItems),
        _saleName: r.sale ? r.sale.nickname : ''
      });
    });

    if (data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="10" style="text-align: center; padding: 40px;">No records</td></tr>';
      return;
    }

    tbody.innerHTML = data.map(function(row) {
      var items = formatItemsForTable(row._itemsJson);
      var price = parseFloat(row.price) || parseFloat(row.total) || 0;
      var fee = parseFloat(row.fee) || 0;
      var total = parseFloat(row.total) || price;
      var paid = parseFloat(row.paid) || 0;
      var balance = parseFloat(row.balance);
      if (isNaN(balance)) balance = total - paid;
      var saleName = row._saleName;
      var status = row.status;
      var actions = '';

      if (status === 'PENDING' || status === 'PARTIAL') {
        if (isManager()) {
          actions = '<button class="btn-action" onclick="openBuybackPaymentModalFromList(\'' + row.id + '\')">Payment</button>';
        } else {
          actions = '<span style="color: var(--text-secondary);">Waiting for payment</span>';
        }
        if (currentUser.role === 'Admin') {
          actions += ' <button class="btn-action" onclick="deleteTransactionSupabase(\'' + row.id + '\',\'BUYBACK\')" style="background:#f44336;margin-left:4px;">🗑️</button>';
        }
      } else {
        var detail = encodeURIComponent(JSON.stringify([
          ['Transaction ID', row.id],
          ['BILL ID', row.bill_id || '-'],
          ['Phone', row.phone],
          ['Items', items],
          ['Price', formatNumber(price) + ' LAK'],
          ['Fee', formatNumber(fee) + ' LAK'],
          ['Total', formatNumber(total) + ' LAK'],
          ['Paid', formatNumber(paid) + ' LAK'],
          ['Balance', formatNumber(balance) + ' LAK'],
          ['Date', formatDateTime(row.date)],
          ['Status', status],
          ['Sale', saleName]
        ]));
        actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Buyback\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
      }

      return '<tr>' +
        '<td>' + row.id + '</td>' +
        '<td>' + (row.bill_id || '-') + '</td>' +
        '<td style="font-size:11px;white-space:nowrap;">' + (row.date ? formatDateTime(row.date) : '') + '</td>' +
        '<td>' + row.phone + '</td>' +
        '<td>' + items + '</td>' +
        '<td>' + formatNumber(price) + '</td>' +
        '<td>' + formatNumber(fee) + '</td>' +
        '<td>' + formatNumber(total) + '</td>' +
        '<td style="color: ' + (balance > 0 ? '#f44336' : '#4caf50') + '; font-weight: bold;">' + formatNumber(balance) + '</td>' +
        '<td><span class="status-badge status-' + status.toLowerCase() + '">' + status + '</span></td>' +
        '<td>' + saleName + '</td>' +
        '<td>' + actions + '</td>' +
        '</tr>';
    }).join('');
  } catch (error) {
    console.error('Error loading buybacks:', error);
  }
}

let buybackCounter = 0;

function addBuybackProduct() {
  buybackCounter++;
  var container = document.getElementById('buybackProducts');
  var productOptions = FIXED_PRODUCTS.map(function(p) {
    return '<option value="' + p.id + '">' + p.name + '</option>';
  }).join('');
  container.insertAdjacentHTML('beforeend',
    '<div class="product-row" id="buyback' + buybackCounter + '">' +
      '<select class="form-select" style="flex: 2;" onchange="calculateBuybackTotal()">' +
        '<option value="">Select Product</option>' + productOptions +
      '</select>' +
      '<input type="number" class="form-input" placeholder="Qty" min="1" style="flex: 1;" oninput="calculateBuybackTotal()">' +
      '<button type="button" class="btn-remove" onclick="document.getElementById(\'buyback' + buybackCounter + '\').remove(); calculateBuybackTotal();">×</button>' +
    '</div>'
  );
}

function calculateBuybackTotal() {
  if (!currentPricing.sell1Baht || currentPricing.sell1Baht === 0) return 0;
  var products = [];
  document.querySelectorAll('#buybackProducts .product-row').forEach(function(row) {
    var productId = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) products.push({ productId: productId, qty: qty });
  });
  var totalPrice = 0;
  products.forEach(function(item) {
    var pricePerPiece = calculateBuybackPrice(item.productId, currentPricing.sell1Baht);
    totalPrice += pricePerPiece * item.qty;
  });
  var total = roundTo1000(totalPrice);
  var el = document.getElementById('buybackPrice');
  if (el) el.value = formatNumber(total) + ' LAK';
  return total;
}

async function calculateBuyback() {
  if (_isSubmitting) return;
  var phone = document.getElementById('buybackPhone').value.replace(/\D/g, '');
  if (!phone || phone.length !== 8) { alert('กรุณากรอกเบอร์โทร 8 หลัก'); return; }
  var billId = document.getElementById('buybackBillId').value.replace(/\D/g, '');
  if (!billId || billId.length !== 6) { alert('กรุณากรอก BILL ID ตัวเลข 6 หลัก'); return; }

  var products = [];
  document.querySelectorAll('#buybackProducts .product-row').forEach(function(row) {
    var productId = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) products.push({ productId: productId, qty: qty });
  });
  if (products.length === 0) { alert('กรุณาเลือกสินค้า'); return; }

  var price = calculateBuybackTotal();

  try {
    _isSubmitting = true;
    showLoading();
    var result = await dbRpc('create_buyback_tx', {
      p_phone: phone,
      p_bill_id: billId,
      p_items: mergeItems(products),
      p_price: price,
      p_fee: 0,
      p_sell_1baht: currentPricing.sell1Baht
    });

    if (result && result.success) {
      endSubmit();
      showToast('✅ สร้างรายการรับซื้อสำเร็จ!');
      closeModal('buybackModal');
      document.getElementById('buybackPhone').value = '';
      document.getElementById('buybackBillId').value = '';
      document.getElementById('buybackProducts').innerHTML = '';
      document.getElementById('buybackPrice').value = '';
      buybackCounter = 0;
      addBuybackProduct();
      loadBuybacks();
    } else {
      alert('❌ เกิดข้อผิดพลาด: ' + (result && result.message ? result.message : 'Unknown'));
      endSubmit();
    }
  } catch (error) {
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    endSubmit();
  }
}

async function loadCurrentPricingForBuyback() {
  try {
    await fetchCurrentPricing();
    return currentPricing.sell1Baht > 0;
  } catch (error) {
    return false;
  }
}

async function openBuybackModal() {
  var hasPrice = await loadCurrentPricingForBuyback();
  if (!hasPrice) {
    alert('❌ ยังไม่มีราคาทองในระบบ! กรุณาไปที่หน้า Products → Set New Price ก่อน');
    return;
  }
  openModal('buybackModal');
}

function resetBuybackDateFilter() {
  var today = getTodayDateString();
  document.getElementById('buybackDateFrom').value = today;
  document.getElementById('buybackDateTo').value = today;
  buybackDateFrom = today;
  buybackDateTo = today;
  loadBuybacks();
}

document.addEventListener('DOMContentLoaded', function() {
  var fromInput = document.getElementById('buybackDateFrom');
  var toInput = document.getElementById('buybackDateTo');
  if (fromInput && toInput) {
    fromInput.addEventListener('change', function() {
      buybackDateFrom = this.value;
      buybackDateTo = toInput.value || buybackDateFrom;
      if (!toInput.value) toInput.value = buybackDateTo;
      if (buybackDateFrom && buybackDateTo) loadBuybacks();
    });
    toInput.addEventListener('change', function() {
      buybackDateTo = this.value;
      buybackDateFrom = fromInput.value || buybackDateTo;
      if (!fromInput.value) fromInput.value = buybackDateFrom;
      if (buybackDateFrom && buybackDateTo) loadBuybacks();
    });
  }
});
