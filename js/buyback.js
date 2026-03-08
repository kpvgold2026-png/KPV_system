async function loadBuybacks() {
  try {
    var tbody = document.getElementById('buybackTable');
    tbody.innerHTML = '<tr><td colspan="10" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';
    const data = await fetchSheetData('Buybacks!A:L');
    
    if (!data || data.length < 2) {
      tbody.innerHTML = '<tr><td colspan="10" style="text-align: center; padding: 40px;">No records</td></tr>';
      return;
    }
    
    var headers = data[0];
    var col = {};
    headers.forEach(function(h, i) { col[h] = i; });
    
    var cPrice = col['Price'] !== undefined ? col['Price'] : 3;
    var cCurrency = col['Currency'] !== undefined ? col['Currency'] : 4;
    var cFee = col['Fee'] !== undefined ? col['Fee'] : 5;
    var cTotal = col['Total'] !== undefined ? col['Total'] : 6;
    var cPaid = col['Paid'] !== undefined ? col['Paid'] : 7;
    var cBalance = col['Balance'] !== undefined ? col['Balance'] : 8;
    var cDate = col['Date'] !== undefined ? col['Date'] : 9;
    var cStatus = col['Status'] !== undefined ? col['Status'] : 10;
    var cCreatedBy = col['Created_By'] !== undefined ? col['Created_By'] : 11;
    
    let filteredData = data.slice(1);
    
    if (currentUser.role === 'User' || isManager()) {
      if (buybackDateFrom || buybackDateTo) {
        filteredData = filterByDateRange(filteredData, cDate, cCreatedBy, buybackDateFrom, buybackDateTo);
      } else {
        filteredData = filterTodayData(filteredData, cDate, cCreatedBy);
      }
    }
    
    if (buybackSortOrder === 'asc') {
      filteredData.sort(function(a, b) { return new Date(a[cDate]) - new Date(b[cDate]); });
    } else {
      filteredData.sort(function(a, b) { return new Date(b[cDate]) - new Date(a[cDate]); });
    }
    
    tbody = document.getElementById('buybackTable');
    if (filteredData.length === 0) {
      tbody.innerHTML = '<tr><td colspan="10" style="text-align: center; padding: 40px;">No records</td></tr>';
    } else {
      tbody.innerHTML = filteredData.map(function(row) {
        var items = formatItemsForTable(row[2]);
        var price = parseFloat(row[cPrice]) || 0;
        var fee = parseFloat(row[cFee]) || 0;
        var total = parseFloat(row[cTotal]) || 0;
        var paid = parseFloat(row[cPaid]) || 0;
        var balance = parseFloat(row[cBalance]) || 0;
        if (total === 0 && price > 0) { total = price; balance = total - paid; }
        var saleName = row[cCreatedBy] || '';
        var status = row[cStatus] || '';
        
        var actions = '';
        
        if (status === 'PENDING' || status === 'PARTIAL') {
          if (isManager()) {
            actions = '<button class="btn-action" onclick="openBuybackPaymentModalFromList(\'' + row[0] + '\')">Payment</button>';
          } else {
            actions = '<span style="color: var(--text-secondary);">Waiting for payment</span>';
          }
          if (currentUser.role === 'Admin') {
            actions += ' <button class="btn-action" onclick="deleteTransaction(\'' + row[0] + '\',\'Buybacks\',\'BUYBACK\')" style="background:#f44336;margin-left:4px;">🗑️</button>';
          }
        } else {
          var detail = encodeURIComponent(JSON.stringify([['Transaction ID', row[0]], ['Phone', row[1]], ['Items', items], ['Price', formatNumber(price) + ' LAK'], ['Fee', formatNumber(fee) + ' LAK'], ['Total', formatNumber(total) + ' LAK'], ['Paid', formatNumber(paid) + ' LAK'], ['Balance', formatNumber(balance) + ' LAK'], ['Date', formatDateTime(row[cDate])], ['Status', status], ['Sale', saleName]]));
          actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Buyback\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
        }
        
        return '<tr>' +
            '<td>' + row[0] + '</td>' +
            '<td>' + row[1] + '</td>' +
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
    }
  } catch (error) {
  }
}

let buybackCounter = 0;

function addBuybackProduct() {
  buybackCounter++;
  const container = document.getElementById('buybackProducts');
  const productOptions = FIXED_PRODUCTS.map(p => 
    `<option value="${p.id}">${p.name}</option>`
  ).join('');
  
  container.insertAdjacentHTML('beforeend', `
    <div class="product-row" id="buyback${buybackCounter}">
      <select class="form-select" style="flex: 2;" onchange="calculateBuybackTotal()">
        <option value="">Select Product</option>
        ${productOptions}
      </select>
      <input type="number" class="form-input" placeholder="Qty" min="1" style="flex: 1;" oninput="calculateBuybackTotal()">
      <button type="button" class="btn-remove" onclick="document.getElementById('buyback${buybackCounter}').remove(); calculateBuybackTotal();">×</button>
    </div>
  `);
}

function calculateBuybackTotal() {
  if (!currentPricing.sell1Baht || currentPricing.sell1Baht === 0) {
    console.log('currentPricing not loaded yet');
    return 0;
  }

  const products = [];
  document.querySelectorAll('#buybackProducts .product-row').forEach(row => {
    const productId = row.querySelector('select').value;
    const qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) {
      products.push({ productId, qty });
    }
  });

  let totalPrice = 0;
  products.forEach(item => {
    const pricePerPiece = calculateBuybackPrice(item.productId, currentPricing.sell1Baht);
    console.log('Buyback:', item.productId, 'price:', pricePerPiece, 'qty:', item.qty);
    totalPrice += pricePerPiece * item.qty;
  });

  const total = roundTo1000(totalPrice);
  console.log('Buyback Total:', total, 'LAK');
  document.getElementById('buybackPrice').value = formatNumber(total) + ' LAK';
  
  return total;
}

async function calculateBuyback() {
  if (_isSubmitting) return;
  const phone = document.getElementById('buybackPhone').value;
  if (!phone) {
    alert('กรุณากรอกเบอร์โทร');
    return;
  }

  const products = [];
  document.querySelectorAll('#buybackProducts .product-row').forEach(row => {
    const productId = row.querySelector('select').value;
    const qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) {
      products.push({ productId, qty });
    }
  });

  if (products.length === 0) {
    alert('กรุณาเลือกสินค้า');
    return;
  }

  const price = calculateBuybackTotal();
  const fee = 0;

  try {
    _isSubmitting = true;
    showLoading();
    const result = await callAppsScript('ADD_BUYBACK', {
      phone,
      products: JSON.stringify(mergeItems(products)),
      price,
      fee,
      user: currentUser.nickname
    });
    
    if (result.success) {
      endSubmit();
      showToast('✅ สร้างรายการรับซื้อสำเร็จ!');
      closeModal('buybackModal');
      
      document.getElementById('buybackPhone').value = '';
      document.getElementById('buybackProducts').innerHTML = '';
      document.getElementById('buybackPrice').value = '';
      
      buybackCounter = 0;
      addBuybackProduct();
      
      loadBuybacks();
    } else {
      alert('❌ เกิดข้อผิดพลาด: ' + result.message);
      endSubmit();
    }
  } catch (error) {
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    endSubmit();
  }
}

async function loadCurrentPricingForBuyback() {
  try {
    const pricingData = await fetchSheetData('Pricing!A:B');
    
    if (pricingData.length > 1) {
      const latestPricing = pricingData[pricingData.length - 1];
      currentPricing = {
        sell1Baht: parseFloat(String(latestPricing[1]).replace(/,/g, '')) || 0,
        buyback1Baht: 0
      };
      
      console.log('Loaded currentPricing for Buyback:', currentPricing);
      return true;
    }
    return false;
  } catch (error) {
    console.error('Error loading pricing:', error);
    return false;
  }
}

async function openBuybackModal() {
  const hasPrice = await loadCurrentPricingForBuyback();
  
  if (!hasPrice || !currentPricing.sell1Baht || currentPricing.sell1Baht === 0) {
    alert('❌ ยังไม่มีราคาทองในระบบ! กรุณาไปที่หน้า Products → Set New Price ก่อน');
    return;
  }
  
  openModal('buybackModal');
}


function resetBuybackDateFilter() {
  const today = getTodayDateString();
  document.getElementById('buybackDateFrom').value = today;
  document.getElementById('buybackDateTo').value = today;
  buybackDateFrom = today;
  buybackDateTo = today;
  loadBuybacks();
}

document.addEventListener('DOMContentLoaded', function() {
  const fromInput = document.getElementById('buybackDateFrom');
  const toInput = document.getElementById('buybackDateTo');
  
  if (fromInput && toInput) {
    fromInput.addEventListener('change', function() {
      buybackDateFrom = this.value;
      if (buybackDateFrom && buybackDateTo) {
        loadBuybacks();
      }
    });
    
    toInput.addEventListener('change', function() {
      buybackDateTo = this.value;
      if (buybackDateFrom && buybackDateTo) {
        loadBuybacks();
      }
    });
  }
});
