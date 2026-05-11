async function loadInventory() {
  try {
    showLoading();
    var rows = await dbSelect('stock_balances', {
      select: 'product_id,gold_type,qty,updated_at',
      useCache: false
    });
    var tbody = document.getElementById('inventoryTable');

    if (!rows || rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="14" style="text-align: center; padding: 40px;">No inventory records</td></tr>';
      hideLoading();
      return;
    }

    var newMap = {};
    var oldMap = {};
    rows.forEach(function(r) {
      var pid = r.product_id;
      var qty = parseFloat(r.qty) || 0;
      if (r.gold_type === 'NEW') newMap[pid] = qty;
      else if (r.gold_type === 'OLD') oldMap[pid] = qty;
    });

    var products = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06', 'G07'];
    var html = products.map(function(pid) {
      var p = FIXED_PRODUCTS.find(function(x) { return x.id === pid; });
      var newQty = newMap[pid] || 0;
      var oldQty = oldMap[pid] || 0;
      var totalQty = newQty + oldQty;
      var weightG = (p ? p.weight_baht * 15 : 0);
      return '<tr>' +
        '<td>' + pid + '</td>' +
        '<td>' + (p ? p.name : 'Unknown') + '</td>' +
        '<td style="color:#4caf50;">' + newQty + '</td>' +
        '<td style="color:#ff9800;">' + oldQty + '</td>' +
        '<td style="font-weight:bold;">' + totalQty + '</td>' +
        '<td>' + weightG.toFixed(2) + ' g</td>' +
        '<td>' + (newQty * weightG).toFixed(2) + ' g</td>' +
        '<td>' + (oldQty * weightG).toFixed(2) + ' g</td>' +
        '<td>' + (totalQty * weightG).toFixed(2) + ' g</td>' +
        '</tr>';
    }).join('');

    tbody.innerHTML = html;
    hideLoading();
  } catch (error) {
    console.error('Error loading inventory:', error);
    hideLoading();
  }
}

async function confirmStockIn() {
  if (typeof confirmStockInNew === 'function') {
    return confirmStockInNew();
  }
  alert('กรุณาใช้ฟอร์ม Stock In ใหม่');
}

function openStockInModal() {
  if (typeof openStockInNewModal === 'function') {
    return openStockInNewModal();
  }
  alert('กรุณาใช้ฟอร์ม Stock In NEW');
}

function addStockInProduct() {
  if (typeof addStockNewProduct === 'function') {
    return addStockNewProduct('stockInProducts');
  }
}
