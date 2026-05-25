async function loadWAC() {
  try {
    showLoading();
    var today = getTodayDateString();

    var resNew = await dbRpc('get_stock_moves', {
      p_gold_type: 'NEW',
      p_date_from: today,
      p_date_to: today
    });
    var resOld = await dbRpc('get_stock_moves', {
      p_gold_type: 'OLD',
      p_date_from: today,
      p_date_to: today
    });

    function reduceLatest(res) {
      var prevW = res && res.prevW ? parseFloat(res.prevW) : 0;
      var prevC = res && res.prevC ? parseFloat(res.prevC) : 0;
      var moves = res && res.moves ? res.moves : [];
      var w = prevW, c = prevC;
      moves.forEach(function(m) {
        var g = parseFloat(m.goldG) || 0;
        var p = parseFloat(m.price) || 0;
        if (m.dir === 'IN') { w += g; c += p; }
        else { w -= g; c -= p; }
      });
      return { g: w, cost: c };
    }

    var n = reduceLatest(resNew);
    var o = reduceLatest(resOld);

    var totalGoldG = n.g + o.g;
    var totalCost = n.cost + o.cost;
    var wacPerG = totalGoldG > 0 ? totalCost / totalGoldG : 0;
    var wacPerBaht = wacPerG * 15;

    document.getElementById('wacSummaryTable').innerHTML =
      '<tr><td>Stock (NEW)</td><td>' + formatWeight(n.g) + ' g</td><td>' + formatNumber(Math.round(n.cost)) + ' LAK</td></tr>' +
      '<tr><td>Stock (OLD)</td><td>' + formatWeight(o.g) + ' g</td><td>' + formatNumber(Math.round(o.cost)) + ' LAK</td></tr>' +
      '<tr style="font-weight:bold;background:rgba(212,175,55,0.1);"><td>ผลรวม</td><td>' + formatWeight(totalGoldG) + ' g</td><td>' + formatNumber(Math.round(totalCost)) + ' LAK</td></tr>';

    document.getElementById('wacCalcTable').innerHTML =
      '<tr><td>ราคา /g</td><td style="font-weight:bold;color:var(--gold-primary);">' + formatNumber(Math.round(wacPerG)) + ' LAK</td></tr>' +
      '<tr><td>ราคา /บาท</td><td style="font-weight:bold;color:var(--gold-primary);">' + formatNumber(Math.round(wacPerBaht)) + ' LAK</td></tr>';

    hideLoading();
  } catch(error) {
    console.error('Error loading WAC:', error);
    hideLoading();
  }
}
