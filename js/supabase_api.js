var _sb = null;

function getSupabase() {
  if (!_sb) {
    _sb = supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY);
  }
  return _sb;
}

async function sbSelect(table, options) {
  var q = getSupabase().from(table).select(options?.columns || '*');
  if (options?.eq) options.eq.forEach(function(e) { q = q.eq(e[0], e[1]); });
  if (options?.gte) options.gte.forEach(function(e) { q = q.gte(e[0], e[1]); });
  if (options?.lte) options.lte.forEach(function(e) { q = q.lte(e[0], e[1]); });
  if (options?.order) q = q.order(options.order[0], { ascending: options.order[1] !== 'desc' });
  if (options?.limit) q = q.limit(options.limit);
  if (options?.in) options.in.forEach(function(e) { q = q.in(e[0], e[1]); });
  var { data, error } = await q;
  if (error) throw new Error(error.message);
  return data || [];
}

async function sbInsert(table, row) {
  var { data, error } = await getSupabase().from(table).insert(row).select();
  if (error) throw new Error(error.message);
  return data?.[0];
}

async function sbUpdate(table, updates, matchCol, matchVal) {
  var { data, error } = await getSupabase().from(table).update(updates).eq(matchCol, matchVal).select();
  if (error) throw new Error(error.message);
  return data?.[0];
}

async function sbDelete(table, matchCol, matchVal) {
  var { error } = await getSupabase().from(table).delete().eq(matchCol, matchVal);
  if (error) throw new Error(error.message);
}

async function sbRpc(fnName, params) {
  var { data, error } = await getSupabase().rpc(fnName, params || {});
  if (error) throw new Error(error.message);
  return data;
}

async function nextCounter(name) {
  var data = await sbRpc('next_counter', { counter_name: name });
  return data;
}

async function getLatestPricing() {
  var rows = await sbSelect('pricing', { order: ['created_at', 'desc'], limit: 1 });
  if (rows.length > 0) {
    currentPricing.sell1Baht = parseFloat(rows[0].sell_1baht) || 0;
    return rows[0];
  }
  return null;
}

async function getLatestPriceRate() {
  var rows = await sbSelect('price_rates', { order: ['created_at', 'desc'], limit: 1 });
  if (rows.length > 0) {
    currentExchangeRates = {
      THB_Sell: parseFloat(rows[0].thb_sell) || 0,
      USD_Sell: parseFloat(rows[0].usd_sell) || 0,
      THB_Buy: parseFloat(rows[0].thb_buy) || 0,
      USD_Buy: parseFloat(rows[0].usd_buy) || 0
    };
    currentPriceRates = {
      thbSell: parseFloat(rows[0].thb_sell) || 0,
      usdSell: parseFloat(rows[0].usd_sell) || 0,
      thbBuy: parseFloat(rows[0].thb_buy) || 0,
      usdBuy: parseFloat(rows[0].usd_buy) || 0
    };
    return rows[0];
  }
  return null;
}

async function getAllStock() {
  return await sbRpc('get_all_stock');
}

async function getAllBalances() {
  return await sbRpc('get_all_balances');
}

async function getWAC() {
  var rows = await sbRpc('calculate_wac');
  if (rows && rows.length > 0) return rows[0];
  return { per_g: 0, per_baht: 0 };
}

async function getBalance(method, bank, currency) {
  var data = await sbRpc('get_balance', { p_method: method, p_bank: bank || '', p_currency: currency });
  return data || 0;
}

async function addNotification(type, message, targetRole, targetUser, tab, createdBy) {
  var id = 'NTF' + Date.now();
  await sbInsert('notifications', {
    id: id, type: type, message: message,
    target_role: targetRole || '', target_user: targetUser || '',
    tab: tab || '', created_by: createdBy || ''
  });
}

async function updateStock(sku, oldNew, refId, qtyChange, user, note) {
  await sbInsert('stock', {
    product_id: sku,
    type: qtyChange > 0 ? 'IN' : 'OUT',
    old_new: oldNew,
    reference_id: refId,
    quantity: qtyChange,
    note: note || '',
    created_by: user
  });
}

async function recordToUserCashbook(username, type, payments, change, refId) {
  var now = new Date().toISOString();
  var bankPayments = [];

  for (var i = 0; i < payments.cash.length; i++) {
    var p = payments.cash[i];
    if (p.amount > 0) {
      await sbInsert('user_cashbook', {
        cb_id: 'U' + Date.now() + '_' + i,
        username: username, type: type, amount: p.amount,
        currency: p.currency, method: 'Cash', bank: '',
        note: 'Cash ' + p.currency + ' for ' + refId, created_by: username
      });
    }
  }

  for (var j = 0; j < payments.bank.length; j++) {
    var pb = payments.bank[j];
    if (pb.amount > 0) {
      await sbInsert('user_cashbook', {
        cb_id: 'U' + Date.now() + '_b' + j,
        username: username, type: type, amount: pb.amount,
        currency: pb.currency, method: 'Bank', bank: pb.bank,
        note: 'Bank ' + pb.bank + ' ' + pb.currency + ' for ' + refId, created_by: username
      });
      bankPayments.push(pb);
    }
  }

  if (change > 0) {
    await sbInsert('user_cashbook', {
      cb_id: 'U' + Date.now() + '_ch',
      username: username, type: type + '_CHANGE', amount: -change,
      currency: 'LAK', method: 'Cash', bank: '',
      note: 'Change for ' + refId, created_by: username
    });
  }

  for (var k = 0; k < bankPayments.length; k++) {
    var bp = bankPayments[k];
    var cbNo = await nextCounter('cashbank_no');
    var cbId = 'CB' + String(cbNo).padStart(5, '0');
    await sbInsert('cashbank', {
      id: cbId, type: type, amount: bp.amount,
      currency: bp.currency, method: 'Bank', bank: bp.bank,
      note: 'Bank ' + bp.bank + ' ' + bp.currency + ' for ' + refId, created_by: username
    });
  }
}

async function recordOldGoldToUser(username, itemsJson, refId, type) {
  var items = typeof itemsJson === 'string' ? JSON.parse(itemsJson) : itemsJson;
  for (var i = 0; i < items.length; i++) {
    if (items[i].qty > 0) {
      await sbInsert('user_gold', {
        username: username, product_id: items[i].productId,
        qty: items[i].qty, type: type,
        reference_id: refId, created_by: username
      });
    }
  }
}

async function addStockMovement(sheetName, refId, type, itemsJson, direction, useBuybackPrice, user, preWac) {
  var table = sheetName === 'StockMove_New' ? 'stock_move_new' : 'stock_move_old';
  var items = typeof itemsJson === 'string' ? JSON.parse(itemsJson) : itemsJson;
  var totalGoldG = 0;
  items.forEach(function(item) { totalGoldG += getGoldWeight(item.productId) * item.qty; });

  var pricing = await getLatestPricing();
  var sell1Baht = pricing ? parseFloat(pricing.sell_1baht) || 0 : 0;

  var totalPrice = 0;
  if (useBuybackPrice) {
    var bb1Baht = sell1Baht - 530000;
    items.forEach(function(item) {
      var p = 0;
      switch(item.productId) {
        case 'G01': p = bb1Baht * 10; break;
        case 'G02': p = bb1Baht * 5; break;
        case 'G03': p = bb1Baht * 2; break;
        case 'G04': p = bb1Baht; break;
        case 'G05': p = bb1Baht / 2; break;
        case 'G06': p = bb1Baht / 4; break;
        case 'G07': p = bb1Baht / 15; break;
      }
      var rounded = item.productId === 'G07' ? Math.floor(p / 1000) * 1000 : Math.round(p / 1000) * 1000;
      totalPrice += rounded * (item.qty || 0);
    });
  } else {
    items.forEach(function(item) {
      totalPrice += calculateSellPrice(item.productId, sell1Baht) * (item.qty || 0);
    });
  }

  var wacPerG = 0, wacPerBaht = 0;
  if (preWac) {
    wacPerG = preWac.perG;
    wacPerBaht = preWac.perBaht;
  } else {
    var wac = await getWAC();
    wacPerG = wac.per_g;
    wacPerBaht = wac.per_baht;
  }

  if (table === 'stock_move_new' && direction === 'OUT') {
    totalPrice = Math.round(totalGoldG * wacPerG);
  }

  await sbInsert(table, {
    ref_id: refId, type: type,
    items: items, gold_g: totalGoldG,
    direction: direction, price: totalPrice,
    username: user, wac_per_g: wacPerG, wac_per_baht: wacPerBaht
  });
}

async function addStockMovementOldOut(refId, type, itemsJson, user, preWac) {
  var fifoResult = await fulfillFIFO(itemsJson);
  var items = typeof itemsJson === 'string' ? JSON.parse(itemsJson) : itemsJson;
  var totalGoldG = 0;
  items.forEach(function(item) { totalGoldG += getGoldWeight(item.productId) * item.qty; });

  var wacPerG = 0, wacPerBaht = 0;
  if (preWac) {
    wacPerG = preWac.perG;
    wacPerBaht = preWac.perBaht;
  } else {
    var wac = await getWAC();
    wacPerG = wac.per_g;
    wacPerBaht = wac.per_baht;
  }
  var outPrice = Math.round(totalGoldG * wacPerG);

  await sbInsert('stock_move_old', {
    ref_id: refId, type: type,
    items: items, gold_g: totalGoldG,
    direction: 'OUT', price: outPrice,
    username: user, wac_per_g: wacPerG, wac_per_baht: wacPerBaht
  });

  return fifoResult;
}

async function addStockMovementCustomCost(table, refId, type, itemsJson, direction, customCost, user, preWac) {
  var items = typeof itemsJson === 'string' ? JSON.parse(itemsJson) : itemsJson;
  var totalGoldG = 0;
  items.forEach(function(item) { totalGoldG += getGoldWeight(item.productId) * item.qty; });

  var wacPerG = 0, wacPerBaht = 0;
  if (preWac) {
    wacPerG = preWac.perG;
    wacPerBaht = preWac.perBaht;
  } else {
    var wac = await getWAC();
    wacPerG = wac.per_g;
    wacPerBaht = wac.per_baht;
  }

  await sbInsert(table, {
    ref_id: refId, type: type,
    items: items, gold_g: totalGoldG,
    direction: direction, price: Math.round(customCost),
    username: user, wac_per_g: wacPerG, wac_per_baht: wacPerBaht
  });
}

async function fulfillFIFO(outItemsJson) {
  var outItems = typeof outItemsJson === 'string' ? JSON.parse(outItemsJson) : outItemsJson;
  var demand = {};
  outItems.forEach(function(item) { demand[item.productId] = (demand[item.productId] || 0) + item.qty; });

  var inRows = await sbSelect('stock_move_old', {
    eq: [['direction', 'IN']],
    order: ['date', 'asc']
  });

  var totalPrice = 0;

  for (var i = 0; i < inRows.length; i++) {
    var row = inRows[i];
    var rowItems = row.items || [];
    var fulfilled = row.fulfilled || [];
    var fulfilledMap = {};
    fulfilled.forEach(function(f) { fulfilledMap[f.productId] = (fulfilledMap[f.productId] || 0) + f.qty; });

    var rowPrice = parseFloat(row.price) || 0;
    var rowGoldG = parseFloat(row.gold_g) || 0;
    var pricePerG = rowGoldG > 0 ? rowPrice / rowGoldG : 0;
    var changed = false;

    for (var j = 0; j < rowItems.length; j++) {
      var pid = rowItems[j].productId;
      var inQty = rowItems[j].qty;
      var alreadyFulfilled = fulfilledMap[pid] || 0;
      var remaining = inQty - alreadyFulfilled;
      if (remaining <= 0 || !demand[pid] || demand[pid] <= 0) continue;
      var take = Math.min(remaining, demand[pid]);
      demand[pid] -= take;
      var weightPerPiece = getGoldWeight(pid);
      totalPrice += Math.round(take * weightPerPiece * pricePerG);
      fulfilledMap[pid] = alreadyFulfilled + take;
      changed = true;
    }

    if (changed) {
      var newFulfilled = [];
      Object.keys(fulfilledMap).forEach(function(pid) {
        if (fulfilledMap[pid] > 0) newFulfilled.push({ productId: pid, qty: fulfilledMap[pid] });
      });
      await sbUpdate('stock_move_old', { fulfilled: newFulfilled }, 'id', row.id);
    }

    var allDone = true;
    Object.keys(demand).forEach(function(pid) { if (demand[pid] > 0) allDone = false; });
    if (allDone) break;
  }

  return { totalPrice: totalPrice };
}

async function recordDiff(txId, type, newItemsJson, oldItemsJson, exchangeFee, premium, switchFee) {
  var weights = {'G01':150,'G02':75,'G03':30,'G04':15,'G05':7.5,'G06':3.75,'G07':1};
  var newGoldG = 0, oldGoldG = 0;

  if (newItemsJson) {
    var nItems = typeof newItemsJson === 'string' ? JSON.parse(newItemsJson) : newItemsJson;
    nItems.forEach(function(item) { newGoldG += (weights[item.productId] || 0) * (item.qty || 0); });
  }
  if (oldItemsJson) {
    var oItems = typeof oldItemsJson === 'string' ? JSON.parse(oldItemsJson) : oldItemsJson;
    oItems.forEach(function(item) { oldGoldG += (weights[item.productId] || 0) * (item.qty || 0); });
  }

  var pricing = await getLatestPricing();
  var sell1Baht = pricing ? parseFloat(pricing.sell_1baht) || 0 : 0;
  var wac = await getWAC();
  var wacPerG = wac.per_g || 0;

  var exFee = Math.round(parseFloat(exchangeFee) || 0);
  var swFee = Math.round(parseFloat(switchFee) || 0);
  var prem = Math.round(parseFloat(premium) || 0);

  var newSellTotal = 0, oldSellTotal = 0;
  if (newItemsJson) {
    var ni = typeof newItemsJson === 'string' ? JSON.parse(newItemsJson) : newItemsJson;
    ni.forEach(function(item) { newSellTotal += calculateSellPrice(item.productId, sell1Baht) * (item.qty || 0); });
  }
  if (oldItemsJson) {
    var oi = typeof oldItemsJson === 'string' ? JSON.parse(oldItemsJson) : oldItemsJson;
    oi.forEach(function(item) { oldSellTotal += calculateSellPrice(item.productId, sell1Baht) * (item.qty || 0); });
  }

  var difference = 0, costDiff = 0, costOldGold = 0;

  if (type === 'SELL') {
    difference = newSellTotal;
    costDiff = Math.round(newGoldG * wacPerG);
  } else if (type === 'TRADEIN') {
    difference = newSellTotal;
    costDiff = Math.round((newGoldG - oldGoldG) * wacPerG);
    costOldGold = oldSellTotal;
  } else if (type === 'EXCHANGE' || type === 'SWITCH' || type === 'FREE_EX') {
    difference = newSellTotal;
    costOldGold = oldSellTotal;
  } else if (type === 'WITHDRAW') {
    exFee = 0; swFee = 0;
  }

  var diffTotal = difference + exFee + swFee + prem - costDiff - costOldGold;

  await sbInsert('diff', {
    transaction_id: txId, type: type, difference: difference,
    exchange_fee: exFee, switch_fee: swFee, premium: prem,
    cost_diff: costDiff, cost_old_gold: costOldGold, diff_total: diffTotal
  });
}

async function logApproval(transactionId, transactionType, decision, approvedBy, note) {
  await sbInsert('approvals', {
    transaction_id: transactionId, transaction_type: transactionType,
    decision: decision, approved_by: approvedBy, note: note || ''
  });
}
