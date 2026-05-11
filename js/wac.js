async function loadWAC() {
  try {
    showLoading();
    var rows = await dbSelect('wac_state', {
      select: 'new_gold_g,new_value,old_gold_g,old_value',
      filters: { id: 'eq.1' },
      limit: 1,
      useCache: false
    });

    var newGoldG = 0, newValue = 0, oldGoldG = 0, oldValue = 0;
    if (rows && rows.length > 0) {
      newGoldG = parseFloat(rows[0].new_gold_g) || 0;
      newValue = parseFloat(rows[0].new_value) || 0;
      oldGoldG = parseFloat(rows[0].old_gold_g) || 0;
      oldValue = parseFloat(rows[0].old_value) || 0;
    }

    var totalGoldG = newGoldG + oldGoldG;
    var totalCost = newValue + oldValue;
    var wacPerG = totalGoldG > 0 ? totalCost / totalGoldG : 0;
    var wacPerBaht = wacPerG * 15;

    document.getElementById('wacSummaryTable').innerHTML =
      '<tr><td>Stock (NEW)</td><td>' + formatWeight(newGoldG) + ' g</td><td>' + formatNumber(newValue) + ' LAK</td></tr>' +
      '<tr><td>Stock (OLD)</td><td>' + formatWeight(oldGoldG) + ' g</td><td>' + formatNumber(oldValue) + ' LAK</td></tr>' +
      '<tr style="font-weight:bold;background:rgba(212,175,55,0.1);"><td>ผลรวม</td><td>' + formatWeight(totalGoldG) + ' g</td><td>' + formatNumber(totalCost) + ' LAK</td></tr>';

    document.getElementById('wacCalcTable').innerHTML =
      '<tr><td>ราคา /g</td><td style="font-weight:bold;color:var(--gold-primary);">' + formatNumber(wacPerG) + ' LAK</td></tr>' +
      '<tr><td>ราคา /บาท</td><td style="font-weight:bold;color:var(--gold-primary);">' + formatNumber(wacPerBaht) + ' LAK</td></tr>';

    hideLoading();
  } catch(error) {
    console.error('Error loading WAC:', error);
    hideLoading();
  }
}
