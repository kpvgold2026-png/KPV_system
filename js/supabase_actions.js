async function actionAddSell(params) {
  var no = await nextCounter('sell_no');
  var sellId = 'SE' + String(no).padStart(5, '0');
  var items = typeof params.items === 'string' ? JSON.parse(params.items) : params.items;
  var total = parseFloat(params.total) || 0;
  var sell1Baht = parseFloat(params.sell1Baht) || currentPricing.sell1Baht;
  var user = params.user || currentUser.nickname;

  await sbInsert('sells', {
    id: sellId, phone: params.phone, items: items,
    total: total, currency: 'LAK', date: new Date().toISOString(),
    status: 'PENDING', created_by: user
  });

  await updateStock(items, 'NEW', sellId, -1, user, 'SELL PENDING');

  await addNotification('NEW_TX', user + ' สร้างขาย ' + sellId, 'Manager,Admin', '', 'sell', user);

  return { success: true, data: { sellId: sellId } };
}

async function actionReviewSell(params) {
  var decision = params.decision || 'APPROVE';
  var id = params.id || params.sellId;
  if (decision === 'APPROVE') {
    await sbUpdate('sells', { status: 'READY' }, 'id', id);
    var sell = (await sbSelect('sells', { eq: [['id', id]] }))[0];
    if (sell) {
      await addNotification('TX_APPROVED', 'ขาย ' + id + ' ผ่านแล้ว', '', sell.created_by, 'sell', params.approvedBy || currentUser.nickname);
    }
  } else {
    await sbUpdate('sells', { status: 'REJECTED' }, 'id', id);
    var sell2 = (await sbSelect('sells', { eq: [['id', id]] }))[0];
    if (sell2) {
      await reverseStockForItems(sell2.items, 'NEW', id, sell2.created_by);
      await addNotification('TX_REJECTED', 'ขาย ' + id + ' ถูกปฏิเสธ', '', sell2.created_by, 'sell', params.approvedBy || currentUser.nickname);
    }
  }
  await logApproval(id, 'SELL', decision, params.approvedBy || currentUser.nickname, params.note || '');
  return { success: true };
}

async function actionConfirmSellPayment(params) {
  var id = params.sellId;
  var payments = typeof params.payments === 'string' ? JSON.parse(params.payments) : params.payments;
  var totalPaid = parseFloat(params.totalPaid) || 0;
  var change = parseFloat(params.change) || 0;
  var user = params.user || currentUser.nickname;
  var sell = (await sbSelect('sells', { eq: [['id', id]] }))[0];
  if (!sell) throw new Error('Sell not found');

  var mainCurrency = 'LAK';
  var mainRate = 1;
  if (payments.cash.length > 0 && payments.cash[0].currency !== 'LAK') {
    mainCurrency = payments.cash[0].currency;
    mainRate = payments.cash[0].rate || 1;
  } else if (payments.bank.length > 0 && payments.bank[0].currency !== 'LAK') {
    mainCurrency = payments.bank[0].currency;
    mainRate = payments.bank[0].rate || 1;
  }
  var displayPaid = totalPaid;
  if (mainCurrency !== 'LAK' && mainRate > 0) {
    displayPaid = payments.cash.concat(payments.bank).reduce(function(sum, p) { return sum + p.amount; }, 0);
  }

  await sbUpdate('sells', {
    status: 'COMPLETED',
    customer_paid: displayPaid,
    customer_currency: mainCurrency,
    exchange_rate: mainRate,
    change_lak: change
  }, 'id', id);

  await recordToUserCashbook(user, 'SELL', payments, change, id);

  var preWac = await getWACValues();
  await addStockMovement('StockMove_New', id, 'SELL', JSON.stringify(sell.items), 'OUT', false, user, preWac);
  await recordDiff(id, 'SELL', JSON.stringify(sell.items), null, 0, 0, 0);

  return { success: true };
}

async function actionAddTradein(params) {
  var no = await nextCounter('tradein_no');
  var tradeinId = 'TI' + String(no).padStart(5, '0');
  var oldGold = typeof params.oldGold === 'string' ? JSON.parse(params.oldGold) : params.oldGold;
  var newGold = typeof params.newGold === 'string' ? JSON.parse(params.newGold) : params.newGold;
  var user = params.user || currentUser.nickname;

  var oldValue = 0;
  oldGold.forEach(function(item) {
    oldValue += calculateSellPrice(item.productId, currentPricing.sell1Baht) * item.qty;
  });

  await sbInsert('tradeins', {
    id: tradeinId, phone: params.phone,
    old_gold: oldGold, new_gold: newGold,
    difference: parseFloat(params.difference) || 0,
    premium: parseFloat(params.premium) || 0,
    total: parseFloat(params.total) || 0,
    date: new Date().toISOString(),
    status: 'PENDING', created_by: user,
    old_gold_value: oldValue
  });

  await updateStock(newGold, 'NEW', tradeinId, -1, user, 'TRADEIN NEW OUT');

  await addNotification('NEW_TX', user + ' สร้าง Trade-in ' + tradeinId, 'Manager,Admin', '', 'tradein', user);

  return { success: true, data: { tradeinId: tradeinId } };
}

async function actionReviewTradein(params) {
  var decision = params.decision || 'APPROVE';
  var id = params.id || params.tradeinId;
  if (decision === 'APPROVE') {
    await sbUpdate('tradeins', { status: 'READY' }, 'id', id);
    var ti = (await sbSelect('tradeins', { eq: [['id', id]] }))[0];
    if (ti) await addNotification('TX_APPROVED', 'Trade-in ' + id + ' ผ่านแล้ว', '', ti.created_by, 'tradein', params.approvedBy);
  } else {
    await sbUpdate('tradeins', { status: 'REJECTED' }, 'id', id);
    var ti2 = (await sbSelect('tradeins', { eq: [['id', id]] }))[0];
    if (ti2) {
      await reverseStockForItems(ti2.new_gold, 'NEW', id, ti2.created_by);
      await addNotification('TX_REJECTED', 'Trade-in ' + id + ' ถูกปฏิเสธ', '', ti2.created_by, 'tradein', params.approvedBy);
    }
  }
  await logApproval(id, 'TRADEIN', decision, params.approvedBy, params.note || '');
  return { success: true };
}

async function actionConfirmTradeinPayment(params) {
  var id = params.tradeinId;
  var payments = typeof params.payments === 'string' ? JSON.parse(params.payments) : params.payments;
  var change = parseFloat(params.change) || 0;
  var user = params.user || currentUser.nickname;
  var ti = (await sbSelect('tradeins', { eq: [['id', id]] }))[0];
  if (!ti) throw new Error('Tradein not found');

  await sbUpdate('tradeins', {
    status: 'COMPLETED',
    customer_paid: parseFloat(params.totalPaid) || 0,
    change_lak: change
  }, 'id', id);

  await recordToUserCashbook(user, 'TRADEIN', payments, change, id);
  await recordOldGoldToUser(user, ti.old_gold, id, 'TRADEIN');

  var preWac = await getWACValues();
  await addStockMovement('StockMove_New', id, 'TRADE-IN', JSON.stringify(ti.new_gold), 'OUT', false, user, preWac);
  await addStockMovement('StockMove_Old', id, 'TRADE-IN', JSON.stringify(ti.old_gold), 'IN', true, user, preWac);
  await recordDiff(id, 'TRADEIN', JSON.stringify(ti.new_gold), JSON.stringify(ti.old_gold), 0, ti.premium, 0);

  await updateStock(ti.old_gold, 'OLD', id, 1, user, 'TRADEIN OLD IN');

  return { success: true };
}

async function actionAddExchange(params) {
  var no = await nextCounter('exchange_no');
  var exchangeId = 'EX' + String(no).padStart(5, '0');
  var oldGold = typeof params.oldGold === 'string' ? JSON.parse(params.oldGold) : params.oldGold;
  var newGold = typeof params.newGold === 'string' ? JSON.parse(params.newGold) : params.newGold;
  var switchOldGold = params.switchOldGold ? (typeof params.switchOldGold === 'string' ? JSON.parse(params.switchOldGold) : params.switchOldGold) : [];
  var freeExOldGold = params.freeExOldGold ? (typeof params.freeExOldGold === 'string' ? JSON.parse(params.freeExOldGold) : params.freeExOldGold) : [];
  var user = params.user || currentUser.nickname;

  var oldValue = 0;
  oldGold.forEach(function(item) {
    oldValue += calculateSellPrice(item.productId, currentPricing.sell1Baht) * item.qty;
  });

  await sbInsert('exchanges', {
    id: exchangeId, phone: params.phone,
    old_gold: oldGold, new_gold: newGold,
    exchange_fee: parseFloat(params.exchangeFee) || 0,
    premium: parseFloat(params.premium) || 0,
    total: parseFloat(params.total) || 0,
    date: new Date().toISOString(),
    status: 'PENDING', created_by: user,
    switch_old_gold: switchOldGold,
    switch_fee: parseFloat(params.switchFee) || 0,
    freeex_old_gold: freeExOldGold,
    freeex_bill_id: params.freeExBillId || '',
    freeex_premium_deduct: parseFloat(params.freeExPremiumDeduct) || 0,
    old_gold_value: oldValue
  });

  await updateStock(newGold, 'NEW', exchangeId, -1, user, 'EXCHANGE NEW OUT');

  if (params.freeExBillId && params.freeExBillSheet) {
    var table = params.freeExBillSheet.toLowerCase();
    try {
      await sbUpdate(table, { freeex_used: exchangeId }, 'id', params.freeExBillId);
    } catch(e) {}
  }

  await addNotification('NEW_TX', user + ' สร้าง Exchange ' + exchangeId, 'Manager,Admin', '', 'exchange', user);

  return { success: true, data: { exchangeId: exchangeId } };
}

async function actionReviewExchange(params) {
  var decision = params.decision || 'APPROVE';
  var id = params.id || params.exchangeId;
  if (decision === 'APPROVE') {
    await sbUpdate('exchanges', { status: 'READY' }, 'id', id);
    var ex = (await sbSelect('exchanges', { eq: [['id', id]] }))[0];
    if (ex) await addNotification('TX_APPROVED', 'Exchange ' + id + ' ผ่านแล้ว', '', ex.created_by, 'exchange', params.approvedBy);
  } else {
    await sbUpdate('exchanges', { status: 'REJECTED' }, 'id', id);
    var ex2 = (await sbSelect('exchanges', { eq: [['id', id]] }))[0];
    if (ex2) {
      await reverseStockForItems(ex2.new_gold, 'NEW', id, ex2.created_by);
      await addNotification('TX_REJECTED', 'Exchange ' + id + ' ถูกปฏิเสธ', '', ex2.created_by, 'exchange', params.approvedBy);
    }
  }
  await logApproval(id, 'EXCHANGE', decision, params.approvedBy, params.note || '');
  return { success: true };
}

async function actionConfirmExchangePayment(params) {
  var id = params.exchangeId;
  var payments = typeof params.payments === 'string' ? JSON.parse(params.payments) : params.payments;
  var change = parseFloat(params.change) || 0;
  var user = params.user || currentUser.nickname;
  var ex = (await sbSelect('exchanges', { eq: [['id', id]] }))[0];
  if (!ex) throw new Error('Exchange not found');

  await sbUpdate('exchanges', {
    status: 'COMPLETED',
    customer_paid: parseFloat(params.totalPaid) || 0,
    change_lak: change
  }, 'id', id);

  if (ex.total > 0) {
    await recordToUserCashbook(user, 'EXCHANGE', payments, change, id);
  }
  await recordOldGoldToUser(user, ex.old_gold, id, 'EXCHANGE');

  var preWac = await getWACValues();
  await addStockMovement('StockMove_New', id, 'EXCHANGE', JSON.stringify(ex.new_gold), 'OUT', false, user, preWac);
  await addStockMovement('StockMove_Old', id, 'EXCHANGE', JSON.stringify(ex.old_gold), 'IN', true, user, preWac);
  await recordDiff(id, 'EXCHANGE', JSON.stringify(ex.new_gold), JSON.stringify(ex.old_gold), ex.exchange_fee, ex.premium, ex.switch_fee);

  await updateStock(ex.old_gold, 'OLD', id, 1, user, 'EXCHANGE OLD IN');

  return { success: true };
}

async function actionAddBuyback(params) {
  var no = await nextCounter('buyback_no');
  var buybackId = 'BB' + String(no).padStart(5, '0');
  var items = typeof params.products === 'string' ? JSON.parse(params.products) : params.products;
  var price = parseFloat(params.price) || 0;
  var fee = parseFloat(params.fee) || 0;
  var total = price;
  var user = params.user || currentUser.nickname;
  var sell1Baht = parseFloat(params.sell1Baht) || currentPricing.sell1Baht;

  await sbInsert('buybacks', {
    id: buybackId, phone: params.phone,
    items: items, price: price,
    sell_1baht: sell1Baht,
    fee: fee, total: total,
    paid: 0, balance: total,
    date: new Date().toISOString(),
    status: 'PENDING', created_by: user
  });

  await addNotification('NEW_TX', user + ' สร้าง Buyback ' + buybackId, 'Manager,Admin', '', 'buyback', user);

  return { success: true, data: { buybackId: buybackId } };
}

async function actionConfirmBuybackPayment(params) {
  var id = params.buybackId;
  var payments = typeof params.payments === 'string' ? JSON.parse(params.payments) : params.payments;
  var user = params.user || currentUser.nickname;
  var fee = parseFloat(params.fee) || 0;
  var bb = (await sbSelect('buybacks', { eq: [['id', id]] }))[0];
  if (!bb) throw new Error('Buyback not found');

  var totalPaid = parseFloat(params.totalPaid) || 0;
  var prevPaid = parseFloat(bb.paid) || 0;
  var newPaid = prevPaid + totalPaid;
  var total = parseFloat(bb.total) || parseFloat(bb.price) || 0;
  var balance = total - newPaid;
  var newStatus = balance <= 0 ? 'COMPLETED' : 'PARTIAL';

  await sbUpdate('buybacks', {
    paid: newPaid,
    balance: Math.max(0, balance),
    fee: fee,
    status: newStatus
  }, 'id', id);

  for (var j = 0; j < payments.bank.length; j++) {
    var pb = payments.bank[j];
    if (pb.amount > 0) {
      var cbNo = await nextCounter('cashbank_no');
      var cbId = 'CB' + String(cbNo).padStart(5, '0');
      var signedAmount = -pb.amount;
      await sbInsert('cashbank', {
        id: cbId, type: 'BUYBACK', amount: signedAmount,
        currency: pb.currency, method: 'Bank', bank: pb.bank,
        note: 'Buyback ' + id, created_by: user
      });
      if (pb.fee && pb.fee > 0) {
        var feeNo = await nextCounter('cashbank_no');
        var feeId = 'CB' + String(feeNo).padStart(5, '0');
        await sbInsert('cashbank', {
          id: feeId, type: 'BUYBACK_FEE', amount: -pb.fee,
          currency: 'LAK', method: 'Cash', bank: '',
          note: 'Fee for ' + id, created_by: user
        });
      }
    }
  }

  for (var i = 0; i < payments.cash.length; i++) {
    var pc = payments.cash[i];
    if (pc.amount > 0) {
      var ccNo = await nextCounter('cashbank_no');
      var ccId = 'CB' + String(ccNo).padStart(5, '0');
      await sbInsert('cashbank', {
        id: ccId, type: 'BUYBACK', amount: -pc.amount,
        currency: pc.currency, method: 'Cash', bank: '',
        note: 'Buyback cash ' + id, created_by: user
      });
    }
  }

  if (newStatus === 'COMPLETED') {
    await updateStock(bb.items, 'OLD', id, 1, user, 'BUYBACK OLD IN');
    await recordOldGoldToUser(user, bb.items, id, 'BUYBACK');

    var preWac = await getWACValues();
    await addStockMovement('StockMove_Old', id, 'BUYBACK', JSON.stringify(bb.items), 'IN', true, user, preWac);
  }

  return { success: true };
}

async function actionAddWithdraw(params) {
  var no = await nextCounter('withdraw_no');
  var withdrawId = 'WD' + String(no).padStart(5, '0');
  var items = typeof params.items === 'string' ? JSON.parse(params.items) : params.items;
  var user = params.user || currentUser.nickname;

  await sbInsert('withdraws', {
    id: withdrawId, phone: params.phone,
    items: items, premium: parseFloat(params.premium) || 0,
    total: parseFloat(params.total) || 0,
    date: new Date().toISOString(),
    status: 'PENDING', created_by: user,
    withdraw_code: params.withdrawCode || ''
  });

  await updateStock(items, 'NEW', withdrawId, -1, user, 'WITHDRAW PENDING');

  await addNotification('NEW_TX', user + ' สร้าง Withdraw ' + withdrawId, 'Manager,Admin', '', 'withdraw', user);

  return { success: true, data: { withdrawId: withdrawId } };
}

async function actionReviewWithdraw(params) {
  var decision = params.decision || 'APPROVE';
  var id = params.id || params.withdrawId;
  if (decision === 'APPROVE') {
    await sbUpdate('withdraws', { status: 'READY' }, 'id', id);
    var wd = (await sbSelect('withdraws', { eq: [['id', id]] }))[0];
    if (wd) await addNotification('TX_APPROVED', 'Withdraw ' + id + ' ผ่านแล้ว', '', wd.created_by, 'withdraw', params.approvedBy);
  } else {
    await sbUpdate('withdraws', { status: 'REJECTED' }, 'id', id);
    var wd2 = (await sbSelect('withdraws', { eq: [['id', id]] }))[0];
    if (wd2) {
      await reverseStockForItems(wd2.items, 'NEW', id, wd2.created_by);
      await addNotification('TX_REJECTED', 'Withdraw ' + id + ' ถูกปฏิเสธ', '', wd2.created_by, 'withdraw', params.approvedBy);
    }
  }
  await logApproval(id, 'WITHDRAW', decision, params.approvedBy, params.note || '');
  return { success: true };
}

async function actionConfirmWithdrawPayment(params) {
  var id = params.id;
  var payments = typeof params.payments === 'string' ? JSON.parse(params.payments) : params.payments;
  var change = parseFloat(params.change) || 0;
  var user = params.user || currentUser.nickname;
  var wd = (await sbSelect('withdraws', { eq: [['id', id]] }))[0];
  if (!wd) throw new Error('Withdraw not found');

  await sbUpdate('withdraws', {
    status: 'COMPLETED',
    paid: parseFloat(params.totalPaid) || 0
  }, 'id', id);

  if (wd.total > 0) {
    await recordToUserCashbook(user, 'WITHDRAW', payments, change, id);
  }

  var preWac = await getWACValues();
  await addStockMovement('StockMove_New', id, 'WITHDRAW', JSON.stringify(wd.items), 'OUT', false, user, preWac);

  return { success: true };
}

async function actionAddCashBank(params) {
  var no = await nextCounter('cashbank_no');
  var cbId = 'CB' + String(no).padStart(5, '0');
  var amount = parseFloat(params.amount) || 0;
  var type = params.type;
  if (type === 'CASH_OUT' || type === 'BANK_WITHDRAW' || type === 'OTHER_EXPENSE') {
    amount = -Math.abs(amount);
  }
  await sbInsert('cashbank', {
    id: cbId, type: type, amount: amount,
    currency: params.currency || 'LAK',
    method: params.method || 'Cash',
    bank: params.bank || '',
    note: params.note || '',
    created_by: currentUser.nickname
  });
  return { success: true };
}

async function actionUpdatePricing(params) {
  await sbInsert('pricing', {
    sell_1baht: parseFloat(params.sell1Baht),
    updated_by: currentUser.nickname
  });
  currentPricing.sell1Baht = parseFloat(params.sell1Baht);
  return { success: true };
}

async function actionAddPriceRate(params) {
  await sbInsert('price_rates', {
    thb_sell: parseFloat(params.thbSell),
    usd_sell: parseFloat(params.usdSell),
    thb_buy: parseFloat(params.thbBuy),
    usd_buy: parseFloat(params.usdBuy),
    updated_by: currentUser.nickname
  });
  await getLatestPriceRate();
  return { success: true };
}

async function actionOpenShift(params) {
  var user = params.user || currentUser.nickname;
  var amount = parseFloat(params.amount) || 0;
  await sbInsert('open_shifts', {
    username: user, status: 'OPEN'
  });
  await sbInsert('user_cashbook', {
    cb_id: 'OPEN' + Date.now(),
    username: user, type: 'OPEN_SHIFT', amount: amount,
    currency: 'LAK', method: 'Cash', bank: '',
    note: 'Open shift', created_by: user
  });
  return { success: true };
}

async function actionSubmitClose(params) {
  var no = await nextCounter('close_no');
  if (!no) no = Date.now();
  var closeId = 'CL' + String(no).padStart(5, '0');
  await sbInsert('close_shifts', {
    id: closeId, username: params.user,
    cash_lak: parseFloat(params.cashLAK) || 0,
    cash_thb: parseFloat(params.cashTHB) || 0,
    cash_usd: parseFloat(params.cashUSD) || 0,
    old_gold: params.oldGold || '',
    status: 'PENDING'
  });
  await addNotification('NEW_TX', params.user + ' ส่งปิดกะ ' + closeId, 'Manager,Admin', '', 'close', params.user);
  return { success: true, data: { closeId: closeId } };
}

async function actionApproveClose(params) {
  await sbUpdate('close_shifts', {
    status: 'APPROVED',
    approved_by: params.approvedBy
  }, 'id', params.closeId);

  var cl = (await sbSelect('close_shifts', { eq: [['id', params.closeId]] }))[0];
  if (cl) {
    var userCashRows = await sbSelect('user_cashbook', { eq: [['username', cl.username]] });
    for (var i = 0; i < userCashRows.length; i++) {
      await sbInsert('log_cashbank', {
        cb_id: userCashRows[i].cb_id,
        type: userCashRows[i].type,
        amount: userCashRows[i].amount,
        currency: userCashRows[i].currency,
        method: userCashRows[i].method,
        bank: userCashRows[i].bank,
        note: userCashRows[i].note,
        created_by: userCashRows[i].created_by
      });
    }
    await getSupabase().from('user_cashbook').delete().eq('username', cl.username);
    await getSupabase().from('user_gold').delete().eq('username', cl.username);
  }
  return { success: true };
}

async function actionRejectClose(params) {
  await sbUpdate('close_shifts', {
    status: 'REJECTED',
    approved_by: params.approvedBy
  }, 'id', params.closeId);
  return { success: true };
}

async function actionCancelClose(params) {
  await sbUpdate('close_shifts', { status: 'CANCELLED' }, 'id', params.closeId);
  return { success: true };
}

async function actionDeleteTransaction(params) {
  var id = params.id;
  var tableMap = {
    'Sells': 'sells', 'Tradeins': 'tradeins', 'Exchanges': 'exchanges',
    'Buybacks': 'buybacks', 'Withdraws': 'withdraws'
  };
  var table = tableMap[params.sheet];
  if (!table) throw new Error('Unknown sheet: ' + params.sheet);

  var row = (await sbSelect(table, { eq: [['id', id]] }))[0];
  if (!row) throw new Error('Not found: ' + id);

  await sbInsert('log', {
    action: 'DELETE', ref_id: id, type: params.type,
    sheet: params.sheet, data: row,
    username: currentUser.nickname
  });

  await sbDelete(table, 'id', id);
  return { success: true, message: 'Deleted ' + id };
}

async function actionTransferOldToNew(params) {
  var items = typeof params.items === 'string' ? JSON.parse(params.items) : params.items;
  var no = await nextCounter('inventory_no');
  var transferId = 'TF' + String(no).padStart(5, '0');
  var user = currentUser.nickname;

  await sbInsert('stock_transfers', {
    id: transferId, items: items, status: 'COMPLETED', created_by: user
  });

  for (var i = 0; i < items.length; i++) {
    await updateStock([items[i]], 'OLD', transferId, -1, user, 'TRANSFER OUT');
    await updateStock([items[i]], 'NEW', transferId, 1, user, 'TRANSFER IN');
  }

  var preWac = await getWACValues();
  await addStockMovementOldOut(transferId, 'TRANSFER', JSON.stringify(items), user, preWac);
  preWac = await getWACValues();
  await addStockMovementCustomCost('stock_move_new', transferId, 'TRANSFER', JSON.stringify(items), 'IN', 0, user, preWac);

  return { success: true, message: 'โอนทอง ' + transferId + ' สำเร็จ' };
}

async function actionStockIn(params) {
  var items = typeof params.items === 'string' ? JSON.parse(params.items) : params.items;
  var no = await nextCounter('stock_in_no');
  var refId = 'SI' + String(no).padStart(5, '0');
  var user = currentUser.nickname;

  for (var i = 0; i < items.length; i++) {
    await updateStock([items[i]], 'NEW', refId, 1, user, params.note || 'Stock In');
  }

  return { success: true, message: 'Stock In ' + refId + ' สำเร็จ' };
}

async function actionStockInNew(params) {
  var items = typeof params.items === 'string' ? JSON.parse(params.items) : params.items;
  var cost = parseFloat(params.cost) || 0;
  var payments = typeof params.payments === 'string' ? JSON.parse(params.payments) : params.payments;
  var fee = parseFloat(params.fee) || 0;
  var user = params.user || currentUser.nickname;
  var no = await nextCounter('stock_in_no');
  var refId = 'SI' + String(no).padStart(5, '0');

  for (var i = 0; i < items.length; i++) {
    await updateStock([items[i]], 'NEW', refId, 1, user, params.note || 'Stock In New');
  }

  for (var p = 0; p < payments.length; p++) {
    var pay = payments[p];
    var cbNo = await nextCounter('cashbank_no');
    var cbId = 'CB' + String(cbNo).padStart(5, '0');
    var lakAmount = (pay.amount || 0) * (pay.rate || 1);
    await sbInsert('cashbank', {
      id: cbId, type: 'STOCK_IN', amount: -Math.abs(pay.amount),
      currency: pay.currency || 'LAK',
      method: pay.method || 'Cash', bank: pay.bank || '',
      note: 'Stock In ' + refId + (pay.rate && pay.rate !== 1 ? '|LAK:' + Math.round(lakAmount) : ''),
      created_by: user
    });
    if (pay.fee && pay.fee > 0) {
      var fNo = await nextCounter('cashbank_no');
      var fId = 'CB' + String(fNo).padStart(5, '0');
      await sbInsert('cashbank', {
        id: fId, type: 'STOCK_IN_FEE', amount: -pay.fee,
        currency: 'LAK', method: 'Cash', bank: '',
        note: 'Fee Stock In ' + refId, created_by: user
      });
    }
  }

  var preWac = await getWACValues();
  await addStockMovementCustomCost('stock_move_new', refId, 'STOCK-IN', JSON.stringify(items), 'IN', cost, user, preWac);

  return { success: true, message: 'Stock In (NEW) ' + refId + ' สำเร็จ' };
}

async function actionStockOutOld(params) {
  var items = typeof params.items === 'string' ? JSON.parse(params.items) : params.items;
  var no = await nextCounter('stock_out_no');
  var refId = 'SO' + String(no).padStart(5, '0');
  var user = currentUser.nickname;

  for (var i = 0; i < items.length; i++) {
    await updateStock([items[i]], 'OLD', refId, -1, user, params.note || 'Stock Out Old');
  }

  var preWac = await getWACValues();
  await addStockMovementOldOut(refId, 'STOCK-OUT', JSON.stringify(items), user, preWac);

  return { success: true, message: 'Stock Out (OLD) ' + refId + ' สำเร็จ' };
}

async function actionTransferCashToShop(params) {
  var user = params.user || currentUser.nickname;
  var transfers = typeof params.transfers === 'string' ? JSON.parse(params.transfers) : params.transfers;

  for (var i = 0; i < transfers.length; i++) {
    var t = transfers[i];
    await sbInsert('user_cashbook', {
      cb_id: 'TR' + Date.now() + '_' + i,
      username: user, type: 'TRANSFER_OUT', amount: -t.amount,
      currency: t.currency, method: 'Cash', bank: '',
      note: 'Transfer to shop', created_by: user
    });
    var cbNo = await nextCounter('cashbank_no');
    var cbId = 'CB' + String(cbNo).padStart(5, '0');
    await sbInsert('cashbank', {
      id: cbId, type: 'TRANSFER_IN', amount: t.amount,
      currency: t.currency, method: 'Cash', bank: '',
      note: 'Transfer from ' + user, created_by: user
    });
  }
  return { success: true };
}

async function actionMarkNotificationsRead(params) {
  var user = params.user;
  var notifs = await sbSelect('notifications', {});
  for (var i = 0; i < notifs.length; i++) {
    var n = notifs[i];
    var readBy = n.read_by || '';
    if (readBy.indexOf(user) < 0) {
      var newReadBy = readBy ? readBy + ',' + user : user;
      await sbUpdate('notifications', { read_by: newReadBy }, 'id', n.id);
    }
  }
  return { success: true };
}

async function actionSaveUser(params) {
  if (params.row && params.row > 0) {
    var existing = await sbSelect('users', { eq: [['username', params.username]] });
    if (existing.length > 0) {
      await sbUpdate('users', {
        role: params.role, nickname: params.name, password: params.pass
      }, 'username', params.username);
    }
  } else {
    var exists = await sbSelect('users', { eq: [['username', params.username]] });
    if (exists.length > 0) throw new Error('Username already exists');
    await sbInsert('users', {
      username: params.username, password: params.pass,
      nickname: params.name, role: params.role
    });
  }
  return { success: true, message: 'Saved' };
}

async function actionDeleteUser(params) {
  if (params.username) {
    await getSupabase().from('users').delete().eq('username', params.username);
  }
  return { success: true, message: 'Deleted' };
}

async function actionInitStock() {
  return { success: true };
}

async function actionGetLiveReport() {
  var allStock = await getAllStock();
  var netTotalG = 0;
  if (allStock) {
    allStock.forEach(function(s) {
      netTotalG += parseFloat(s.new_qty || 0) + parseFloat(s.old_qty || 0);
    });
  }
  var reports = await sbSelect('reports', { order: ['date', 'desc'], limit: 1 });
  var carryForward = reports.length > 0 ? parseFloat(reports[0].net_total_g) || 0 : 0;
  var diff = netTotalG - carryForward;
  return { success: true, data: { netTotal: netTotalG, carryForward: carryForward, diff: diff } };
}

async function actionAutoCalculateReports() {
  return { success: true, calculated: 0 };
}

async function actionGetStockMoves(params) {
  var table = params.sheet === 'StockMove_New' ? 'stock_move_new' : 'stock_move_old';
  var today = getTodayLocalStr();
  var rows = await sbSelect(table, { order: ['date', 'asc'] });

  var prevW = 0, prevC = 0;
  var todayMoves = [];

  rows.forEach(function(r) {
    var d = r.date ? r.date.split('T')[0] : '';
    var move = {
      id: r.ref_id, type: r.type,
      items: JSON.stringify(r.items || []),
      goldG: parseFloat(r.gold_g) || 0,
      dir: r.direction, price: parseFloat(r.price) || 0,
      user: r.username,
      wacG: parseFloat(r.wac_per_g) || 0,
      wacB: parseFloat(r.wac_per_baht) || 0
    };
    if (d < today) {
      if (move.dir === 'IN') { prevW += move.goldG; prevC += move.price; }
      else { prevW -= move.goldG; prevC -= move.price; }
    } else if (d === today) {
      todayMoves.push(move);
    }
  });

  return { success: true, data: { prevW: prevW, prevC: prevC, moves: todayMoves } };
}

async function actionGetStockMovesRange(params) {
  var table = params.sheet === 'StockMove_New' ? 'stock_move_new' : 'stock_move_old';
  var rows = await sbSelect(table, {
    gte: [['date', params.dateFrom + 'T00:00:00']],
    lte: [['date', params.dateTo + 'T23:59:59']],
    order: ['date', 'asc']
  });

  var moves = rows.map(function(r) {
    return {
      id: r.ref_id, type: r.type,
      goldG: parseFloat(r.gold_g) || 0,
      dir: r.direction, price: parseFloat(r.price) || 0
    };
  });

  return { success: true, data: { moves: moves } };
}

async function updateStock(items, oldNew, refId, direction, user, note) {
  var itemsArr = typeof items === 'string' ? JSON.parse(items) : items;
  for (var i = 0; i < itemsArr.length; i++) {
    var item = itemsArr[i];
    await sbInsert('stock', {
      product_id: item.productId,
      type: direction > 0 ? 'IN' : 'OUT',
      old_new: oldNew,
      reference_id: refId,
      quantity: direction * item.qty,
      note: note || '',
      created_by: user
    });
  }
}

async function reverseStockForItems(items, oldNew, refId, user) {
  var itemsArr = typeof items === 'string' ? JSON.parse(items) : items;
  for (var i = 0; i < itemsArr.length; i++) {
    var item = itemsArr[i];
    await sbInsert('stock', {
      product_id: item.productId,
      type: 'IN',
      old_new: oldNew,
      reference_id: refId + '_REV',
      quantity: item.qty,
      note: 'REVERSE',
      created_by: user
    });
  }
}

async function getWACValues() {
  var wac = await getWAC();
  return { perG: wac.per_g || 0, perBaht: wac.per_baht || 0 };
}

async function actionConfirmSwitchPayment(params) {
  return await actionConfirmExchangePayment({
    exchangeId: params.switchId || params.exchangeId,
    payments: params.payments,
    totalPaid: params.totalPaid,
    change: params.change,
    user: params.user
  });
}

async function actionConfirmFreeExchangePayment(params) {
  return await actionConfirmExchangePayment({
    exchangeId: params.freeExId || params.exchangeId,
    payments: params.payments,
    totalPaid: params.totalPaid,
    change: params.change,
    user: params.user
  });
}

var ACTION_MAP = {
  'ADD_SELL': actionAddSell,
  'REVIEW_SELL': actionReviewSell,
  'CONFIRM_SELL_PAYMENT': actionConfirmSellPayment,
  'ADD_TRADEIN': actionAddTradein,
  'REVIEW_TRADEIN': actionReviewTradein,
  'CONFIRM_TRADEIN_PAYMENT': actionConfirmTradeinPayment,
  'ADD_EXCHANGE': actionAddExchange,
  'REVIEW_EXCHANGE': actionReviewExchange,
  'CONFIRM_EXCHANGE_PAYMENT': actionConfirmExchangePayment,
  'CONFIRM_SWITCH_PAYMENT': actionConfirmSwitchPayment,
  'CONFIRM_FREE_EXCHANGE_PAYMENT': actionConfirmFreeExchangePayment,
  'ADD_BUYBACK': actionAddBuyback,
  'CONFIRM_BUYBACK_PAYMENT': actionConfirmBuybackPayment,
  'ADD_WITHDRAW': actionAddWithdraw,
  'REVIEW_WITHDRAW': actionReviewWithdraw,
  'CONFIRM_WITHDRAW_PAYMENT': actionConfirmWithdrawPayment,
  'ADD_CASHBANK': actionAddCashBank,
  'UPDATE_PRICING': actionUpdatePricing,
  'ADD_PRICE_RATE': actionAddPriceRate,
  'OPEN_SHIFT': actionOpenShift,
  'SUBMIT_CLOSE': actionSubmitClose,
  'APPROVE_CLOSE': actionApproveClose,
  'REJECT_CLOSE': actionRejectClose,
  'CANCEL_CLOSE': actionCancelClose,
  'DELETE_TRANSACTION': actionDeleteTransaction,
  'TRANSFER_OLD_TO_NEW': actionTransferOldToNew,
  'STOCK_IN': actionStockIn,
  'STOCK_IN_NEW': actionStockInNew,
  'STOCK_OUT_OLD': actionStockOutOld,
  'TRANSFER_CASH_TO_SHOP': actionTransferCashToShop,
  'MARK_NOTIFICATIONS_READ': actionMarkNotificationsRead,
  'SAVE_USER': actionSaveUser,
  'DELETE_USER': actionDeleteUser,
  'INIT_STOCK': actionInitStock,
  'GET_LIVE_REPORT': actionGetLiveReport,
  'AUTO_CALCULATE_REPORTS': actionAutoCalculateReports,
  'GET_STOCK_MOVES': actionGetStockMoves,
  'GET_STOCK_MOVES_RANGE': actionGetStockMovesRange
};

async function callAppsScript(action, params) {
  params = params || {};
  var fn = ACTION_MAP[action];
  if (!fn) {
    console.error('Unknown action:', action);
    return { success: false, message: 'Unknown action: ' + action };
  }
  try {
    var result = await fn(params);
    return result;
  } catch (e) {
    console.error('Action error:', action, e);
    return { success: false, message: e.message };
  }
}

var executeGoogleScript = callAppsScript;
