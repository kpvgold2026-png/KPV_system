// [R15-1] tab WAC — ดึงจาก RPC get_wac_state() (แหล่งเดียวกับ Dashboard / Accounting / confirm_*)
//   เดิมคำนวณเองจาก get_stock_moves (NEW + OLD FIFO) → ตัวเลขไม่ตรงกับ wac_state ที่ระบบใช้ตัดต้นทุนจริง
//   WAC/บาท = wac_per_baht จาก SQL (= wac_per_g × 15 แบบไม่ปัดเศษ) — ปัดเศษตอนแสดงผลเท่านั้น
async function loadWAC() {
  try {
    showLoading();

    var w = await dbRpc('get_wac_state', {});
    if (!w || w.success === false) {
      throw new Error(w && w.message ? w.message : 'get_wac_state failed');
    }

    var newG = parseFloat(w.new_gold_g) || 0;
    var newC = parseFloat(w.new_value) || 0;
    var oldG = parseFloat(w.old_gold_g) || 0;
    var oldC = parseFloat(w.old_value) || 0;
    var totalGoldG = parseFloat(w.total_g) || (newG + oldG);
    var totalCost = parseFloat(w.total_value) || (newC + oldC);
    var wacPerG = parseFloat(w.wac_per_g) || 0;
    var wacPerBaht = parseFloat(w.wac_per_baht) || (wacPerG * 15);

    document.getElementById('wacSummaryTable').innerHTML =
      '<tr><td>Stock (NEW)</td><td>' + formatWeight(newG) + ' g</td><td>' + formatNumber(Math.round(newC)) + ' LAK</td></tr>' +
      '<tr><td>Stock (OLD)</td><td>' + formatWeight(oldG) + ' g</td><td>' + formatNumber(Math.round(oldC)) + ' LAK</td></tr>' +
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
