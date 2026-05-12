async function loadWAC() {
  try {
    showLoading();

    var dbData = await fetchSheetData('_database!A1:G31');

    var newGoldG = 0, newValue = 0, oldGoldG = 0, oldValue = 0;

    if (dbData.length >= 31) {
      newGoldG = parseFloat(dbData[30][0]) || 0;
      newValue = parseFloat(dbData[30][1]) || 0;
      oldGoldG = parseFloat(dbData[30][2]) || 0;
      oldValue = parseFloat(dbData[30][3]) || 0;
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