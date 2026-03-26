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
  if (options?.neq) options.neq.forEach(function(e) { q = q.neq(e[0], e[1]); });
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
  return await sbRpc('next_counter', { counter_name: name });
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
      LAK: 1,
      THB_Sell: parseFloat(rows[0].thb_sell) || 0,
      USD_Sell: parseFloat(rows[0].usd_sell) || 0,
      THB_Buy: parseFloat(rows[0].thb_buy) || 0,
      USD_Buy: parseFloat(rows[0].usd_buy) || 0,
      THB: parseFloat(rows[0].thb_sell) || 0,
      USD: parseFloat(rows[0].usd_sell) || 0
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
  return await sbRpc('get_balance', { p_method: method, p_bank: bank || '', p_currency: currency }) || 0;
}

async function addNotification(type, message, targetRole, targetUser, tab, createdBy) {
  var id = 'NTF' + Date.now();
  await sbInsert('notifications', {
    id: id, type: type, message: message,
    target_role: targetRole || '', target_user: targetUser || '',
    tab: tab || '', created_by: createdBy || ''
  });
}

async function recordToUserCashbook(username, type, payments, change, refId) {
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

  var sell1Baht = currentPricing.sell1Baht;

  var totalPrice = 0;
  if (useBuybackPrice) {
    items.forEach(function(item) {
      totalPrice += calculateBuybackPrice(item.productId, sell1Baht) * (item.qty || 0);
    });
  } else {
    items.forEach(function(item) {
      totalPrice += calculateSellPrice(item.productId, sell1Baht) * (item.qty || 0);
    });
  }

  var wacPerG = preWac ? preWac.perG : 0;
  var wacPerBaht = preWac ? preWac.perBaht : 0;

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

  var wacPerG = preWac ? preWac.perG : 0;
  var wacPerBaht = preWac ? preWac.perBaht : 0;
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

  await sbInsert(table, {
    ref_id: refId, type: type,
    items: items, gold_g: totalGoldG,
    direction: direction, price: Math.round(customCost),
    username: user,
    wac_per_g: preWac ? preWac.perG : 0,
    wac_per_baht: preWac ? preWac.perBaht : 0
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

  var sell1Baht = currentPricing.sell1Baht;
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

function invalidateCache() {}

async function batchFetchAll() {
  await getLatestPricing();
  await getLatestPriceRate();
}

async function fetchSheetData(range) {
  return await fetchSupabaseData(range);
}

async function fetchSupabaseData(range) {
  var sheetName = range.split('!')[0].replace(/'/g, '');

  var tableMap = {
    '_database': '_database',
    'Sells': 'sells',
    'Tradeins': 'tradeins',
    'Exchanges': 'exchanges',
    'Buybacks': 'buybacks',
    'Withdraws': 'withdraws',
    'CashBank': 'cashbank',
    'Diff': 'diff',
    'Close': 'close_shifts',
    'PriceRate': 'price_rates',
    'Pricing': 'pricing',
    '_notifications': 'notifications',
    '_log': 'log',
    'StockMove_Old': 'stock_move_old',
    'StockMove_New': 'stock_move_new',
    'Stock_Old': 'stock_summary_old',
    'Stock_New': 'stock_summary_new',
    '_log_cashbank': 'log_cashbank',
    'Reports': 'reports',
    'Stock': 'stock',
    'Inventory': 'stock'
  };

  if (sheetName === '_database') {
    return await buildDatabaseSheet(range);
  }

  if (sheetName.endsWith('_Gold')) {
    var goldUser = sheetName.replace('_Gold', '');
    return await buildUserGoldSheet(goldUser);
  }

  if (!tableMap[sheetName]) {
    return await buildUserCashSheet(sheetName);
  }

  var table = tableMap[sheetName];

  if (table === 'sells') return await buildSellsSheet();
  if (table === 'tradeins') return await buildTradeinsSheet();
  if (table === 'exchanges') return await buildExchangesSheet();
  if (table === 'buybacks') return await buildBuybacksSheet();
  if (table === 'withdraws') return await buildWithdrawsSheet();
  if (table === 'cashbank') return await buildCashBankSheet();
  if (table === 'diff') return await buildDiffSheet();
  if (table === 'close_shifts') return await buildCloseSheet();
  if (table === 'price_rates') return await buildPriceRateSheet();
  if (table === 'pricing') return await buildPricingSheet();
  if (table === 'notifications') return await buildNotificationsSheet();
  if (table === 'log') return await buildLogSheet();
  if (table === 'stock_move_old') return await buildStockMoveSheet('stock_move_old');
  if (table === 'stock_move_new') return await buildStockMoveSheet('stock_move_new');
  if (table === 'log_cashbank') return await buildLogCashbankSheet();
  if (table === 'reports') return await buildReportsSheet();

  var rows = await sbSelect(table, { order: ['id', 'desc'] });
  return [['header']].concat(rows.map(function(r) { return Object.values(r); }));
}

async function buildSellsSheet() {
  var rows = await sbSelect('sells', { order: ['date', 'desc'] });
  var header = ['ID','Phone','Items','Total','Currency','CustomerPaid','CustomerCurrency','ExchangeRate','ChangeLAK','Date','Status','Created_By'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.phone, JSON.stringify(r.items), r.total, r.currency, r.customer_paid, r.customer_currency, r.exchange_rate, r.change_lak, r.date, r.status, r.created_by];
  }));
}

async function buildTradeinsSheet() {
  var rows = await sbSelect('tradeins', { order: ['date', 'desc'] });
  var header = ['ID','Phone','OldGold','NewGold','Difference','Premium','Total','CustomerPaid','CustomerCurrency','ExchangeRate','ChangeLAK','Date','Status','Created_By','FreeEx_Used'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.phone, JSON.stringify(r.old_gold), JSON.stringify(r.new_gold), r.difference, r.premium, r.total, r.customer_paid, r.customer_currency, r.exchange_rate, r.change_lak, r.date, r.status, r.created_by, r.freeex_used];
  }));
}

async function buildExchangesSheet() {
  var rows = await sbSelect('exchanges', { order: ['date', 'desc'] });
  var header = ['ID','Phone','OldGold','NewGold','ExchangeFee','Premium','Total','CustomerPaid','CustomerCurrency','ExchangeRate','ChangeLAK','Date','Status','Created_By','SwitchOldGold','SwitchFee','FreeExOldGold','FreeExBillId','FreeExPremiumDeduct','FreeEx_Used'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.phone, JSON.stringify(r.old_gold), JSON.stringify(r.new_gold), r.exchange_fee, r.premium, r.total, r.customer_paid, r.customer_currency, r.exchange_rate, r.change_lak, r.date, r.status, r.created_by, JSON.stringify(r.switch_old_gold || []), r.switch_fee, JSON.stringify(r.freeex_old_gold || []), r.freeex_bill_id, r.freeex_premium_deduct, r.freeex_used];
  }));
}

async function buildBuybacksSheet() {
  var rows = await sbSelect('buybacks', { order: ['date', 'desc'] });
  var header = ['ID','Phone','Items','Price','Currency','Fee','Total','Paid','Balance','Date','Status','Created_By'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.phone, JSON.stringify(r.items), r.price, 'LAK', r.fee, r.total, r.paid, r.balance, r.date, r.status, r.created_by];
  }));
}

async function buildWithdrawsSheet() {
  var rows = await sbSelect('withdraws', { order: ['date', 'desc'] });
  var header = ['ID','Phone','Items','Premium','Total','Paid','Date','Status','Created_By','Note','FreeEx_Used','WithdrawCode'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.phone, JSON.stringify(r.items), r.premium, r.total, r.paid, r.date, r.status, r.created_by, r.note, r.freeex_used, r.withdraw_code];
  }));
}

async function buildCashBankSheet() {
  var rows = await sbSelect('cashbank', { order: ['date', 'desc'] });
  var header = ['ID','Type','Amount','Currency','Method','Bank','Note','Date','Created_By'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.type, r.amount, r.currency, r.method, r.bank, r.note, r.date, r.created_by];
  }));
}

async function buildDiffSheet() {
  var rows = await sbSelect('diff', { order: ['date', 'desc'] });
  var header = ['TxID','Type','Difference','ExchangeFee','SwitchFee','Premium','CostDiff','CostOldGold','DiffTotal','Date'];
  return [header].concat(rows.map(function(r) {
    return [r.transaction_id, r.type, r.difference, r.exchange_fee, r.switch_fee, r.premium, r.cost_diff, r.cost_old_gold, r.diff_total, r.date];
  }));
}

async function buildCloseSheet() {
  var rows = await sbSelect('close_shifts', { order: ['date', 'desc'] });
  var header = ['ID','Username','Date','CashLAK','CashTHB','CashUSD','OldGold','CreatedAt','Status','ApprovedBy','NewGold'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.username, r.date, r.cash_lak, r.cash_thb, r.cash_usd, r.old_gold, r.created_at, r.status, r.approved_by, r.new_gold];
  }));
}

async function buildPriceRateSheet() {
  var rows = await sbSelect('price_rates', { order: ['created_at', 'asc'] });
  var header = ['Date','THB_Sell','USD_Sell','THB_Buy','USD_Buy','Updated_By'];
  return [header].concat(rows.map(function(r) {
    return [r.created_at, r.thb_sell, r.usd_sell, r.thb_buy, r.usd_buy, r.updated_by];
  }));
}

async function buildPricingSheet() {
  var rows = await sbSelect('pricing', { order: ['created_at', 'asc'] });
  var header = ['Date','Sell1Baht','Updated_By'];
  return [header].concat(rows.map(function(r) {
    return [r.created_at, r.sell_1baht, r.updated_by];
  }));
}

async function buildNotificationsSheet() {
  var rows = await sbSelect('notifications', { order: ['created_at', 'desc'] });
  var header = ['ID','Type','Message','TargetRole','TargetUser','Tab','CreatedBy','CreatedAt','ReadBy'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.type, r.message, r.target_role, r.target_user, r.tab, r.created_by, r.created_at, r.read_by];
  }));
}

async function buildLogSheet() {
  var rows = await sbSelect('log', { order: ['date', 'desc'] });
  var header = ['Date','Action','RefID','Type','Sheet','Data','Username'];
  return [header].concat(rows.map(function(r) {
    return [r.date, r.action, r.ref_id, r.type, r.sheet, JSON.stringify(r.data), r.username];
  }));
}

async function buildStockMoveSheet(table) {
  var rows = await sbSelect(table, { order: ['date', 'asc'] });
  var header = ['Date','RefID','Type','Items','GoldG','Direction','Price','Username','WAC_G','WAC_B'];
  return [header].concat(rows.map(function(r) {
    return [r.date, r.ref_id, r.type, JSON.stringify(r.items), r.gold_g, r.direction, r.price, r.username, r.wac_per_g, r.wac_per_baht];
  }));
}

async function buildLogCashbankSheet() {
  var rows = await sbSelect('log_cashbank', { order: ['date', 'desc'] });
  var header = ['ID','CbID','Type','Amount','Currency','Method','Bank','Note','Date','Created_By'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.cb_id, r.type, r.amount, r.currency, r.method, r.bank, r.note, r.date, r.created_by];
  }));
}

async function buildReportsSheet() {
  var rows = await sbSelect('reports', { order: ['date', 'asc'] });
  var header = ['Date','CarryForward','NetTotal'];
  return [header].concat(rows.map(function(r) {
    return [r.date, r.carry_forward_g, r.net_total_g];
  }));
}

async function buildDatabaseSheet(range) {
  var allStock = await getAllStock();
  var allBalances = await getAllBalances();
  var wac = await getWAC();
  var users = await sbSelect('users', { eq: [['active', true]], order: ['role', 'asc'] });

  var pids = ['G01','G02','G03','G04','G05','G06','G07'];
  var newQty = {}, oldQty = {};
  pids.forEach(function(p) { newQty[p] = 0; oldQty[p] = 0; });
  if (allStock) {
    allStock.forEach(function(s) {
      newQty[s.product_id] = parseFloat(s.new_qty) || 0;
      oldQty[s.product_id] = parseFloat(s.old_qty) || 0;
    });
  }

  var cashBal = { Cash: { LAK:0, THB:0, USD:0 }, BCEL: { LAK:0, THB:0, USD:0 }, LDB: { LAK:0, THB:0, USD:0 }, OTHER: { LAK:0, THB:0, USD:0 } };
  if (allBalances) {
    allBalances.forEach(function(b) {
      var key = b.method === 'Cash' ? 'Cash' : (b.bank || 'OTHER');
      if (!cashBal[key]) key = 'OTHER';
      if (cashBal[key]) cashBal[key][b.currency] = (cashBal[key][b.currency] || 0) + parseFloat(b.balance);
    });
  }

  var rows = [];
  for (var i = 0; i < 33; i++) rows.push(['','','','','','','','','','','','','']);

  rows[6] = pids.map(function(p) { return newQty[p]; });
  rows[9] = pids.map(function(p) { return oldQty[p]; });

  rows[16] = [cashBal.Cash.LAK, cashBal.Cash.THB, cashBal.Cash.USD, '', cashBal.OTHER.LAK, cashBal.OTHER.THB, cashBal.OTHER.USD];
  rows[19] = [cashBal.BCEL.LAK, cashBal.BCEL.THB, cashBal.BCEL.USD];
  rows[22] = [cashBal.LDB.LAK, cashBal.LDB.THB, cashBal.LDB.USD];

  var newG = 0, oldG = 0;
  pids.forEach(function(p) { newG += newQty[p] * getGoldWeight(p); oldG += oldQty[p] * getGoldWeight(p); });
  var wacG = wac.per_g || 0;
  var newVal = newG * wacG;
  var oldVal = oldG * wacG;
  rows[30] = [newG, newVal, oldG, oldVal];

  for (var u = 0; u < users.length; u++) {
    rows.push([users[u].role, users[u].nickname, users[u].username, users[u].password]);
  }

  return rows;
}

async function buildUserCashSheet(username) {
  var rows = await sbSelect('user_cashbook', { eq: [['username', username]], order: ['date', 'asc'] });
  var header = ['ID','CbID','Amount','Currency','Method','Bank','Note','Date','Created_By'];
  return [header].concat(rows.map(function(r) {
    return [r.id, r.cb_id, r.amount, r.currency, r.method, r.bank, r.note, r.date, r.created_by];
  }));
}

async function buildUserGoldSheet(username) {
  var rows = await sbSelect('user_gold', { eq: [['username', username]], order: ['date', 'asc'] });
  var header = ['ProductID','Qty','Type','ReferenceID','Date','Created_By'];
  return [header].concat(rows.map(function(r) {
    return [r.product_id, r.qty, r.type, r.reference_id, r.date, r.created_by];
  }));
}

async function fetchExchangeRates() {
  await getLatestPriceRate();
  return currentExchangeRates;
}

async function fetchCurrentPricing() {
  await getLatestPricing();
  return currentPricing;
}
