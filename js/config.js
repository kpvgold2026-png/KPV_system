const CONFIG = {
  API_KEY: 'AIzaSyAB6yjxTB0TNbEk2C68aOP5u0IkdmK12tg',
  SHEET_ID: '1FF4odviKZ2LnRvPf8ltM0o_jxM0ZHuJHBlkQCjC3sxA',
  SCRIPT_URL: 'https://script.google.com/macros/s/AKfycbziDXIkJa_VIXVJpRnwv5aYDq425OU5O1vkDvMXEDmzj5KAzg80PJQFtN5DKOmlv0qp/exec'
};

let USERS = {};

const FIXED_PRODUCTS = [
  { id: 'G01', name: '10 บาท', unit: 'แท่ง', weight: 10 },
  { id: 'G02', name: '5 บาท', unit: 'แท่ง', weight: 5 },
  { id: 'G03', name: '2 บาท', unit: 'แท่ง', weight: 2 },
  { id: 'G04', name: '1 บาท', unit: 'แท่ง', weight: 1 },
  { id: 'G05', name: '2 สลึง', unit: 'แท่ง', weight: 0.5 },
  { id: 'G06', name: '1 สลึง', unit: 'แท่ง', weight: 0.25 },
  { id: 'G07', name: '1 กรัม', unit: 'แท่ง', weight: 1/15 }
];

const GOLD_WEIGHTS = {
  'G01': 10, 
  'G02': 5, 
  'G03': 2, 
  'G04': 1,
  'G05': 0.5, 
  'G06': 0.25,
  'G07': 1/15
};

const PREMIUM_PRODUCTS = ['G05', 'G06'];
let PREMIUM_PER_PIECE = 120000;

const EXCHANGE_FEES = {
  'G01': 1690000,
  'G02': 845000,
  'G03': 338000,
  'G04': 169000,
  'G05': 99000,
  'G06': 99000,
  'G07': 99000
};

const EXCHANGE_FEES_SWITCH = {
  'G01': 2690000,
  'G02': 1345000,
  'G03': 538000,
  'G04': 269000,
  'G05': 139000,
  'G06': 139000,
  'G07': 139000
};

let currentUser = null;
let currentPricing = {
  sell1Baht: 0,
  buyback1Baht: 0
};

let currentPriceRates = {
  thbSell: 0,
  usdSell: 0,
  thbBuy: 0,
  usdBuy: 0
};

let sellSortOrder = 'desc';
let tradeinSortOrder = 'desc';
let exchangeSortOrder = 'desc';
let switchSortOrder = 'desc';
let freeExchangeSortOrder = 'desc';
let buybackSortOrder = 'desc';
let withdrawSortOrder = 'desc';
let tradeinOldCounter = 0;
let tradeinNewCounter = 0;

let sellDateFrom = null;
let sellDateTo = null;
let tradeinDateFrom = null;
let tradeinDateTo = null;
let exchangeDateFrom = null;
let exchangeDateTo = null;
let switchDateFrom = null;
let switchDateTo = null;
let freeExchangeDateFrom = null;
let freeExchangeDateTo = null;
let buybackDateFrom = null;
let buybackDateTo = null;
let withdrawDateFrom = null;
let withdrawDateTo = null;

let currentExchangeRates = { LAK: 1, THB: 0, USD: 0, THB_Sell: 0, USD_Sell: 0, THB_Buy: 0, USD_Buy: 0 };
let currentReconcileType = null;
let currentReconcileData = {};