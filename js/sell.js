async function loadSells() {
  try {
    var tbody = document.getElementById('sellTable');
    tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';
    const data = await fetchSheetData('Sells!A:L');
    
    let filteredData = data.slice(1);
    
    if (currentUser.role === 'User' || isManager()) {
      if (sellDateFrom || sellDateTo) {
        filteredData = filterByDateRange(filteredData, 9, 11, sellDateFrom, sellDateTo);
      } else {
        filteredData = filterTodayData(filteredData, 9, 11);
      }
    }
    
    if (sellSortOrder === 'asc') {
      filteredData.sort((a, b) => new Date(a[9]) - new Date(b[9]));
    } else {
      filteredData.sort((a, b) => new Date(b[9]) - new Date(a[9]));
    }
    
    if (filteredData.length === 0) {
      tbody.innerHTML = '<tr><td colspan="8" style="text-align: center; padding: 40px;">No records</td></tr>';
    } else {
      tbody.innerHTML = filteredData.map(row => {
        const items = formatItemsForTable(row[2]);
        const premium = calculatePremiumFromItems(row[2]);
        const saleName = row[11];
        const status = row[10];
        
        let actions = '';
        
        if (status === 'PENDING') {
          if (isManager()) {
            actions = `<button class="btn-action" onclick="reviewSell('${row[0]}')">Review</button>`;
          } else {
            actions = '<span style="color: var(--text-secondary);">Waiting for review</span>';
          }
        } else if (status === 'READY') {
          if (currentUser.role === 'User') {
            actions = `<button class="btn-action" onclick="openSellPayment('${row[0]}')">Confirm</button>`;
          } else {
            actions = '<span style="color: var(--text-secondary);">Waiting for confirmation</span>';
          }
        } else {
          var paid = parseFloat(row[5]) || 0;
          var changeLak = parseFloat(row[8]) || 0;
          var payInfo = paid > 0 ? formatNumber(paid) + ' ' + (row[6] || 'LAK') : '-';
          var detail = encodeURIComponent(JSON.stringify([['Transaction ID', row[0]], ['Phone', row[1]], ['Items', formatItemsForTable(row[2])], ['Total', formatNumber(row[3]) + ' LAK'], ['Customer Paid', payInfo], ['Change', changeLak > 0 ? formatNumber(changeLak) + ' LAK' : '-'], ['Date', formatDateTime(row[9])], ['Status', status], ['Sale', row[11]]]));
          actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Sell\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
        }
        
        return `
          <tr>
            <td>${row[0]}</td>
            <td>${row[1]}</td>
            <td>${items}</td>
            <td>${formatNumber(premium)}</td>
            <td>${formatNumber(row[3])}</td>
            <td><span class="status-badge status-${status.toLowerCase()}">${status}</span></td>
            <td>${saleName}</td>
            <td>${actions}</td>
          </tr>
        `;
      }).join('');
    }
  } catch (error) {
    console.error('❌ Error loading sells:', error);
  }
}


let sellCounter = 0;

function addSellProduct() {
  sellCounter++;
  const container = document.getElementById('sellProducts');
  const row = document.createElement('div');
  row.className = 'product-row';
  row.id = `sellProduct${sellCounter}`;
  row.innerHTML = `
    <select class="form-select" onchange="calculateSellTotal()">
      <option value="">เลือกสินค้า...</option>
      ${FIXED_PRODUCTS.map(p => `<option value="${p.id}">${p.name}</option>`).join('')}
    </select>
    <input type="number" class="form-input" placeholder="จำนวน" min="1" step="1" oninput="calculateSellTotal()">
    <button type="button" class="btn-remove" onclick="removeSellProduct(${sellCounter})">×</button>
  `;
  container.appendChild(row);
}

function removeSellProduct(id) {
  const row = document.getElementById(`sellProduct${id}`);
  if (row) {
    row.remove();
    calculateSellTotal();
  }
}

async function submitSell() {
  if (_isSubmitting) return;
  var phone = document.getElementById('sellPhone').value;
  if (!phone) {
    alert('กรุณากรอกเบอร์โทร');
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
    var result = await callAppsScript('ADD_SELL', {
      phone: phone,
      items: JSON.stringify(mergeItems(items)),
      total: totalPrice
    });

    if (result.success) {
      endSubmit();
      showToast('✅ สร้างรายการขายสำเร็จ!');
      closeModal('sellModal');
      document.getElementById('sellPhone').value = '';
      document.getElementById('sellProducts').innerHTML = '';
      sellCounter = 0;
      addSellProduct();
      loadSells();
    } else {
      alert('❌ เกิดข้อผิดพลาด: ' + result.message);
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
  const data = await fetchSheetData('_database!A7:G7');
  if (data.length === 0) return 0;
  
  const productIndexMap = {
    'G01': 0, 'G02': 1, 'G03': 2, 'G04': 3,
    'G05': 4, 'G06': 5, 'G07': 6
  };
  
  const index = productIndexMap[productId];
  if (index === undefined) return 0;
  
  return parseFloat(data[0][index]) || 0;
}

function viewSellDetails(sellId) {
  alert(`View details for ${sellId} (Manager view only)`);
}

async function reviewSell(sellId) {
  if (!confirm('Approve this sell transaction?')) return;
  
  try {
    showLoading();
    const result = await callAppsScript('REVIEW_SELL', { sellId });
    
    if (result.success) {
      showToast('✅ Transaction reviewed and ready for confirmation!');
      loadSells();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

function calculateSellTotal() {
  let totalPrice = 0;
  let totalPremium = 0;
  
  
  document.querySelectorAll('#sellProducts .product-row').forEach((row, index) => {
    const productId = row.querySelector('select').value;
    const qty = parseInt(row.querySelector('input').value) || 0;
    
    if (productId && qty > 0) {
      const productName = FIXED_PRODUCTS.find(p => p.id === productId)?.name || productId;
      const pricePerPiece = calculateSellPrice(productId, currentPricing.sell1Baht);
      const lineTotal = pricePerPiece * qty;
      
      
      totalPrice += lineTotal;
      
      if (PREMIUM_PRODUCTS.includes(productId)) {
        const premium = PREMIUM_PER_PIECE * qty;
        totalPremium += premium;
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
    const data = await fetchSheetData('Pricing!A:C');
    if (data.length > 1) {
      const latestPricing = data[data.length - 1];
      currentPricing = {
        sell1Baht: parseFloat(String(latestPricing[1]).replace(/,/g, '')) || 0,
        buyback1Baht: parseFloat(String(latestPricing[2]).replace(/,/g, '')) || 0
      };
    }
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
      if (sellDateFrom && sellDateTo) {
        loadSells();
      }
    });
    
    toInput.addEventListener('change', function() {
      sellDateTo = this.value;
      if (sellDateFrom && sellDateTo) {
        loadSells();
      }
    });
  }
});
