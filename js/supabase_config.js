var CONFIG = {
  SUPABASE_URL: 'YOUR_SUPABASE_URL',
  SUPABASE_ANON_KEY: 'YOUR_SUPABASE_ANON_KEY'
};

var FIXED_PRODUCTS = [
  { id: 'G01', name: '10 บาท', weight: 150 },
  { id: 'G02', name: '5 บาท', weight: 75 },
  { id: 'G03', name: '2 บาท', weight: 30 },
  { id: 'G04', name: '1 บาท', weight: 15 },
  { id: 'G05', name: '2 สลึง', weight: 7.5 },
  { id: 'G06', name: '1 สลึง', weight: 3.75 },
  { id: 'G07', name: '1 กรัม', weight: 1 }
];

var currentUser = null;
var currentPricing = { sell1Baht: 0 };
var currentExchangeRates = { THB_Sell: 0, USD_Sell: 0, THB_Buy: 0, USD_Buy: 0 };
var currentPriceRates = { thbSell: 0, usdSell: 0, thbBuy: 0, usdBuy: 0 };

let sellDateFrom = null;
let sellDateTo = null;
let tradeinDateFrom = null;
let tradeinDateTo = null;
let exchangeDateFrom = null;
let exchangeDateTo = null;
let withdrawDateFrom = null;
let withdrawDateTo = null;
let buybackDateFrom = null;
let buybackDateTo = null;
