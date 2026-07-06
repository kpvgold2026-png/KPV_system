var historySellDateFrom = '';
var historySellDateTo = '';

async function loadHistorySell() {
  try {
    showLoading();
    var today = getTodayDateString();
    if (!historySellDateFrom && !historySellDateTo) {
      historySellDateFrom = today;
      historySellDateTo = today;
    }
    document.getElementById('historySellDateFrom').value = historySellDateFrom;
    document.getElementById('historySellDateTo').value = historySellDateTo;

    var fromEl = document.getElementById('historySellDateFrom');
    var toEl = document.getElementById('historySellDateTo');
    fromEl.onchange = function() { historySellDateFrom = this.value; loadHistorySell(); };
    toEl.onchange = function() { historySellDateTo = this.value; loadHistorySell(); };

    // get_history_txs ไม่รองรับ offset/pagination → ใช้เพดาน 5000 + เตือนเมื่อชนเพดาน (ห้ามตัดเงียบ)
    var data = await dbRpc('get_history_txs', {
      p_date_from: historySellDateFrom,
      p_date_to: historySellDateTo,
      p_limit: 5000
    });
    // เช็คจากจำนวนดิบก่อนกรอง buyback ออก ไม่งั้นเตือนพลาด
    var truncated = Array.isArray(data) && data.length >= 5000;
    var warnRow = truncated
      ? '<tr><td colspan="15" style="text-align:center;padding:10px;color:#ff9800;font-weight:600;">⚠️ ข้อมูลเกิน 5,000 รายการ แสดงไม่ครบ — กรุณาแคบช่วงวันที่</td></tr>'
      : '';

    // Buyback มี tab ของตัวเอง → ไม่แสดงใน History Sell (กันทุก case/null)
    if (Array.isArray(data)) {
      data = data.filter(function(r) { return String(r.type || '').toUpperCase() !== 'BUYBACK'; });
    }

    if (!Array.isArray(data) || data.length === 0) {
      document.getElementById('historySellTable').innerHTML = warnRow + '<tr><td colspan="15" style="text-align:center;padding:40px;">No records</td></tr>';
      hideLoading();
      return;
    }

    var typeColors = { 'SELL': '#4caf50', 'TRADEIN': '#2196f3', 'EXCHANGE': '#ff9800', 'WITHDRAW': '#f44336', 'BUYBACK': '#9c27b0' };
    var typeLabels = { 'SELL': 'SELL', 'TRADEIN': 'TRADE-IN', 'EXCHANGE': 'EXCHANGE', 'WITHDRAW': 'WITHDRAW', 'BUYBACK': 'BUYBACK' };

    document.getElementById('historySellTable').innerHTML = warnRow + data.map(function(r) {
      var typeLabel = typeLabels[r.type] || r.type;
      var color = typeColors[r.type] || '#666';
      var items = r.items || [];
      var oldItems = items.filter(function(i) { return i.role === 'OLD' || i.role === 'FOC'; }).map(function(i) { return { productId: i.productId, qty: i.qty }; });
      var newItems = items.filter(function(i) { return i.role === 'NEW'; }).map(function(i) { return { productId: i.productId, qty: i.qty }; });
      var oldGoldStr = oldItems.length > 0 ? formatItemsForTable(JSON.stringify(oldItems)) : '-';
      var newGoldStr = newItems.length > 0 ? formatItemsForTable(JSON.stringify(newItems)) : '-';

      var paid = parseFloat(r.paid) || 0;
      var total = parseFloat(r.total) || 0;
      var actions = '';

      if (r.status === 'COMPLETED' || r.status === 'PARTIAL' || r.status === 'PAID') {
        // type-specific item slices for richer detail popup
        var switchItems = items.filter(function(i) { return i.role === 'SWITCH'; }).map(function(i) { return { productId: i.productId, qty: i.qty }; });
        var freeExItems = items.filter(function(i) { return i.role === 'FREE_EX'; }).map(function(i) { return { productId: i.productId, qty: i.qty }; });
        var focItems = items.filter(function(i) { return i.role === 'FOC'; }).map(function(i) { return { productId: i.productId, qty: i.qty }; });
        var switchStr = switchItems.length ? formatItemsForTable(JSON.stringify(switchItems)) : '-';
        var freeExStr = freeExItems.length ? formatItemsForTable(JSON.stringify(freeExItems)) : '-';
        var focStr = focItems.length ? formatItemsForTable(JSON.stringify(focItems)) : '-';

        var detailArr = [
          ['Type', typeLabel],
          ['Transaction ID', r.id],
          ['BILL ID', r.bill_id || '-'],
          ['Phone', r.phone],
          ['Old Gold', oldGoldStr],
          ['New Gold', newGoldStr]
        ];
        // type-specific extras
        if (r.type === 'TRADEIN') {
          if (focItems.length) detailArr.push(['FOC Gold', focStr]);
          if (r.foc_premium_deduct) detailArr.push(['FOC Premium Deduct', formatNumber(parseFloat(r.foc_premium_deduct) || 0) + ' LAK']);
          if (r.foc_bill_ref) detailArr.push(['FOC Bill Ref', r.foc_bill_ref]);
          if (r.diff) detailArr.push(['Difference', formatNumber(parseFloat(r.diff) || 0) + ' LAK']);
        } else if (r.type === 'EXCHANGE') {
          if (switchItems.length) detailArr.push(['Switch Old Gold', switchStr]);
          if (freeExItems.length) detailArr.push(['Free Ex Old Gold', freeExStr]);
          if (r.free_ex_bill_ref) detailArr.push(['Free Ex Bill Ref', r.free_ex_bill_ref]);
          if (r.ex_fee) detailArr.push(['Exchange Fee', formatNumber(parseFloat(r.ex_fee) || 0) + ' LAK']);
          if (r.switch_fee) detailArr.push(['Switch Fee', formatNumber(parseFloat(r.switch_fee) || 0) + ' LAK']);
        } else if (r.type === 'WITHDRAW') {
          if (r.withdraw_code) detailArr.push(['Withdraw Code', r.withdraw_code]);
          if (r.diff) detailArr.push(['Difference', formatNumber(parseFloat(r.diff) || 0) + ' LAK']);
        }
        if (r.premium) detailArr.push(['Premium', formatNumber(parseFloat(r.premium) || 0) + ' LAK']);
        detailArr.push(['Total', formatNumber(total) + ' LAK']);
        detailArr.push(['Customer Paid', paid > 0 ? formatNumber(paid) + ' ' + (r.currency || 'LAK') : '-']);
        if (r.note) detailArr.push(['Note', r.note]);
        detailArr.push(['Date', formatDateTime(r.date)]);
        detailArr.push(['Status', r.status]);
        detailArr.push(['Sale', r.sale_nickname || '']);

        var detail = encodeURIComponent(JSON.stringify(detailArr));
        actions = '<button class="btn-action" onclick="viewTransactionDetail(\'' + typeLabel + '\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
      } else if (r.status === 'PENDING' && isManager()) {
        var reviewMap = { 'SELL': 'reviewSell', 'TRADEIN': 'reviewTradein', 'EXCHANGE': 'reviewExchange', 'WITHDRAW': 'reviewWithdraw' };
        var fn = reviewMap[r.type];
        if (fn) {
          actions = '<button class="btn-action" onclick="' + fn + '(\'' + r.id + '\')" style="background:#ff9800;color:#fff;border-color:#ff9800;">Review</button>';
        }
      } else if (r.status === 'PENDING') {
        actions = '<span style="color:var(--text-secondary);font-size:12px;">Pending</span>';
      } else if (r.status === 'APPROVED' || r.status === 'READY') {
        actions = '<span style="color:var(--text-secondary);font-size:12px;">Ready</span>';
      }

      if (r.status !== 'COMPLETED' && r.status !== 'PARTIAL' && r.status !== 'PAID' && currentUser.role === 'Admin') {
        actions += ' <button class="btn-action" onclick="deleteTransactionSupabase(\'' + r.id + '\',\'' + r.type + '\')" style="background:#f44336;margin-left:4px;">🗑️</button>';
      }

      var dim = 'style="color:var(--text-secondary);"';
      // ฟิลด์ที่แต่ละประเภทธุรกรรมควรแสดง
      // SELL: ขายตรง ลูกค้าจ่ายเต็มราคา → ไม่มี diff/ex_fee/switch_fee
      // TRADEIN: เอาทองเก่ามาเทรด → มี diff (ลูกค้าจ่ายส่วนต่าง)
      // EXCHANGE: เปลี่ยนชิ้น → มี ex_fee/switch_fee
      // WITHDRAW: ฝากไว้แล้วถอน → มี diff
      var typeCols = {
        'SELL':     { diff: false, ex_fee: false, switch_fee: false, premium: true },
        'TRADEIN':  { diff: true,  ex_fee: false, switch_fee: false, premium: true },
        'EXCHANGE': { diff: false, ex_fee: true,  switch_fee: true,  premium: true },
        'WITHDRAW': { diff: true,  ex_fee: false, switch_fee: false, premium: true },
        'BUYBACK':  { diff: false, ex_fee: false, switch_fee: false, premium: false }
      };
      function fmt(val, field) {
        var cols = typeCols[r.type] || {};
        if (!cols[field]) return '<span ' + dim + '>-</span>';
        var n = parseFloat(val);
        return (!n) ? '<span ' + dim + '>-</span>' : formatNumber(n);
      }
      return '<tr>' +
        '<td style="white-space:nowrap;">' + r.id + '</td>' +
        '<td>' + (r.bill_id || '-') + '</td>' +
        '<td style="font-size:11px;white-space:nowrap;">' + formatDateTime(r.date) + '</td>' +
        '<td>' + r.phone + '</td>' +
        '<td><span style="background:' + color + ';color:#fff;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;white-space:nowrap;">' + typeLabel + '</span></td>' +
        '<td>' + (oldGoldStr === '-' ? '<span ' + dim + '>-</span>' : oldGoldStr) + '</td>' +
        '<td>' + (newGoldStr === '-' ? '<span ' + dim + '>-</span>' : newGoldStr) + '</td>' +
        '<td>' + fmt(r.diff, 'diff') + '</td>' +
        '<td>' + fmt(r.ex_fee, 'ex_fee') + '</td>' +
        '<td>' + fmt(r.switch_fee, 'switch_fee') + '</td>' +
        '<td>' + fmt(r.premium, 'premium') + '</td>' +
        '<td style="font-weight:bold;">' + formatNumber(total) + '</td>' +
        '<td><span class="status-badge status-' + (r.status || '').toLowerCase() + '">' + r.status + '</span></td>' +
        '<td>' + (r.sale_nickname || '') + '</td>' +
        '<td>' + actions + '</td>' +
        '</tr>';
    }).join('');

    hideLoading();
  } catch(e) {
    console.error('Error loading history sell:', e);
    hideLoading();
  }
}

function resetHistorySellDateFilter() {
  historySellDateFrom = getTodayDateString();
  historySellDateTo = getTodayDateString();
  loadHistorySell();
}
