// Runs selected production MQL5 functions through deterministic broker mocks.
// This validates control flow only; it does not emulate MT5 event timing or fills.
const fs = require('node:fs');
const path = require('node:path');

const eaPath = path.join(__dirname, '..', 'Experts', 'XAUUSD_OneClick_StopGrid_EA.mq5');
const source = fs.readFileSync(eaPath, 'utf8');
const functionNames = [
  'PendingGridStillValid',
  'LotForLevel',
  'LevelMargin',
  'GridMarginIsAffordable',
  'ManualEntryAccepted',
  'IsBetterLine',
  'ProtectionLineTouched',
  'RequestProtectionExit',
  'ProcessProtectionExitDeal',
  'ProtectionExitMatches',
  'UpdateTrailingProtection',
  'RecoveryStopPrice',
  'UpdateRecoveryProtection',
  'ManageFormulaClose',
];

function extractFunction(name) {
  const header = new RegExp(`^(?:bool|void|double) ${name}\\([^)]*\\)\\s*\\{`, 'm').exec(source);
  if (!header) throw new Error(`Function not found: ${name}`);
  let cursor = header.index + header[0].length;
  let depth = 1;
  while (cursor < source.length && depth > 0) {
    if (source[cursor] === '{') depth += 1;
    if (source[cursor] === '}') depth -= 1;
    cursor += 1;
  }
  if (depth !== 0) throw new Error(`Unbalanced function: ${name}`);
  return source.slice(header.index, cursor);
}

const argumentNames = {
  PendingGridStillValid: ['manualPrice', 'direction', 'expiryMsc', 'bid', 'ask', 'nowMsc'],
  LotForLevel: ['level', 'manualLot'],
  LevelMargin: ['direction', 'rawPrice', 'requestedLot'],
  GridMarginIsAffordable: ['direction', 'manualPrice', 'manualLot', 'projectedLevel', 'gridMargin'],
  ManualEntryAccepted: ['manualLot'],
  IsBetterLine: ['candidate', 'current', 'direction'],
  ProtectionLineTouched: ['basket', 'bid', 'ask'],
  RequestProtectionExit: ['basket'],
  ProcessProtectionExitDeal: ['dealTicket'],
  ProtectionExitMatches: ['lineDirection', 'linePrice', 'positionDirection', 'reason', 'exitLevel'],
  UpdateTrailingProtection: ['basket', 'direction'],
  RecoveryStopPrice: ['basket'],
  UpdateRecoveryProtection: ['basket'],
  ManageFormulaClose: [],
};

function transformGetBasketStats(code) {
  return code.replace(/GetBasketStats\(([\s\S]*?)\);/g, (_match, rawArgs) => {
    const args = rawArgs.split(',').map((part) => part.trim());
    if (args.length !== 8) throw new Error(`Unexpected GetBasketStats arguments: ${rawArgs}`);
    const [basket, ...outputs] = args;
    return `({ ${outputs.join(', ')} } = GetBasketStats(${basket}));`;
  });
}

function transformFunction(name, original) {
  let code = original.replace(
    new RegExp(`^(?:bool|void|double) ${name}\\([^)]*\\)\\s*\\{`),
    `function ${name}(${argumentNames[name].join(', ')}) {`,
  );

  code = code.replace(
    /double newestEntry, previousEntry;\s*if\(!GetTrailingAnchors\(basket, direction, newestEntry, previousEntry\)\)\s*return;/,
    'let { ok: anchorsOk, newestEntry, previousEntry } = GetTrailingAnchors(basket, direction);\n   if(!anchorsOk) return;',
  );
  code = code.replace(
    /double cutNewestEntry, cutPreviousEntry;\s*if\(!GetTrailingAnchors\(g_closeBaskets\[b\], cutDirection, cutNewestEntry, cutPreviousEntry\)\)\s*continue;/,
    'let { ok: cutAnchorsOk, newestEntry: cutNewestEntry, previousEntry: cutPreviousEntry } = GetTrailingAnchors(g_closeBaskets[b], cutDirection);\n            if(!cutAnchorsOk) continue;',
  );
  code = code.replace(
    /double cutAnchorEntry, cutAnchorPrevious;\s*if\(!GetTrailingAnchors\(g_closeBaskets\[b\], winningDirection, cutAnchorEntry, cutAnchorPrevious\) \|\|\s*cutAnchorEntry <= 0\.0\)/,
    'let { ok: cutAnchorOk, newestEntry: cutAnchorEntry, previousEntry: cutAnchorPrevious } = GetTrailingAnchors(g_closeBaskets[b], winningDirection);\n         if(!cutAnchorOk || cutAnchorEntry <= 0.0)',
  );
  code = code.replace(
    /double margin = 0\.0;\s*ResetLastError\(\);\s*if\(!OrderCalcMargin\(type, _Symbol, lot, price, margin\) \|\| margin < 0\.0\)/,
    'let margin = 0.0;\n   ResetLastError();\n   let calcOk;\n   ({ ok: calcOk, margin } = OrderCalcMargin(type, _Symbol, lot, price));\n   if(!calcOk || margin < 0.0)',
  );
  code = transformGetBasketStats(code);
  code = code
    .replace(/\((?:ENUM_DEAL_ENTRY|ENUM_DEAL_REASON|ENUM_DEAL_TYPE|ulong|uint|long|int|double)\)/g, '')
    .replace(/\b(?:double|int|bool|string|ulong|uint|long|ENUM_DEAL_REASON|ENUM_DEAL_TYPE|ENUM_ORDER_TYPE)\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*;/g, 'let $1;')
    .replace(/\b(?:double|int|bool|string|ulong|uint|long|ENUM_DEAL_REASON|ENUM_DEAL_TYPE|ENUM_ORDER_TYPE)\s+([A-Za-z_]\w*)\s*=/g, 'let $1 =')
    .replace(/for\(int\s+/g, 'for(let ');
  return code;
}

const productionFunctions = functionNames
  .map((name) => transformFunction(name, extractFunction(name)))
  .join('\n\n');

// MQL5 constants used by the extracted functions.
const SYMBOL_BID = 1;
const SYMBOL_ASK = 2;
const DEAL_SYMBOL = 3;
const DEAL_ENTRY = 4;
const DEAL_REASON = 5;
const DEAL_TYPE = 6;
const DEAL_POSITION_ID = 7;
const DEAL_SL = 8;
const DEAL_TP = 9;
const ORDER_SYMBOL = 10;
const ORDER_MAGIC = 11;
const ORDER_COMMENT = 12;
const SYMBOL_MARGIN_HEDGED = 13;
const ACCOUNT_EQUITY = 14;
const ACCOUNT_MARGIN = 15;
const ORDER_TYPE_BUY = 16;
const ORDER_TYPE_SELL = 17;
const DEAL_ENTRY_OUT = 20;
const DEAL_ENTRY_IN = 21;
const DEAL_REASON_SL = 30;
const DEAL_REASON_TP = 31;
const DEAL_REASON_EXPERT = 32;
const DEAL_TYPE_BUY = 40;
const DEAL_TYPE_SELL = 41;

let g_closeBaskets;
let g_tickSize = 0.001;
let _Digits = 3;
let _Symbol = 'XAUUSD';
let InpUseFormulaClose;
let InpUseRecoveryFormula;
let InpMaxLosersBeforeCut;
let InpOrdersPerSide;
let InpWinnerCutCount;
let InpRecoverySLArmCents;
let InpMagicNumber = 20260904;
let InpMinMarginLevelPercent;
let InpFixedLotUnit;
let InpMinManualLot;
let InpMaxManualLot;
let InpMaxConcurrentBaskets;
let marginHedged;
let equity;
let usedMargin;
let marginPerLot;
let calcMarginFails;
let volumeMin;
let InpProtectSpreadBuffer = 0.05;
let bid;
let ask;
let live;
let deal;
let saves;
let sideCloses;
let basketCloses;
let applies;
let failsafeApplies;
let failsafeDirection;
let statsReads;
let pendingDeletes;
let sideCloseSucceeds;
let basketCloseSucceeds;
let pendingDeleteSucceeds;

function newBasket() {
  return {
    rootOrderTicket: 100,
    manualPositionId: 101,
    protectionArmed: false,
    protectionDirection: 0,
    protectionPrice: 0,
    marketExitRequested: false,
    bankedLoserCount: 0,
    winnerCutAnchorPrice: 0,
    winnerCutDirection: 0,
    cleanTrailActive: false,
    recoverySLArmed: false,
    retainedProtectionPrice: 0,
    retainedProtectionDirection: 0,
  };
}

function reset(direction = 1) {
  g_closeBaskets = [newBasket()];
  InpUseFormulaClose = true;
  InpUseRecoveryFormula = true;
  InpMaxLosersBeforeCut = 0;
  InpOrdersPerSide = 5;
  InpWinnerCutCount = 3;
  InpRecoverySLArmCents = 200;
  InpMinMarginLevelPercent = 300;
  InpFixedLotUnit = 0.01;
  InpMinManualLot = 0;
  InpMaxManualLot = 0;
  InpMaxConcurrentBaskets = 0;
  marginHedged = 0;
  equity = 10000;
  usedMargin = 0;
  marginPerLot = 400;
  calcMarginFails = false;
  volumeMin = 0.01;
  bid = 4007;
  ask = 4007.2;
  live = direction === 1
    ? { buys: 3, sells: 1, buyAdvance: 20, sellAdvance: -10, buyLosers: 0, sellLosers: 1,
        pendingBuy: 1, pendingSell: 1, newestBuy: 4006, previousBuy: 4003,
        newestSell: 4009, previousSell: 4012 }
    : { buys: 1, sells: 3, buyAdvance: -10, sellAdvance: 20, buyLosers: 1, sellLosers: 0,
        pendingBuy: 1, pendingSell: 1, newestBuy: 4006, previousBuy: 4003,
        newestSell: 4009, previousSell: 4012 };
  deal = {
    entry: DEAL_ENTRY_OUT,
    reason: DEAL_REASON_SL,
    type: DEAL_TYPE_SELL,
    positionId: 101,
    magic: InpMagicNumber,
    symbol: _Symbol,
    openingSymbol: _Symbol,
    tag: 'G#100',
    sl: 4003.05,
    tp: 4003.05,
    openingOrderAvailable: true,
  };
  saves = 0;
  sideCloses = 0;
  basketCloses = 0;
  applies = 0;
  failsafeApplies = 0;
  failsafeDirection = null;
  statsReads = 0;
  pendingDeletes = 0;
  sideCloseSucceeds = false;
  basketCloseSucceeds = false;
  pendingDeleteSucceeds = true;
}

function Print() {}
function DoubleToString(value) { return String(value); }
function MathAbs(value) { return Math.abs(value); }
function GridStepPrice() { return 3; }
function TrailArmPrice() { return 3; }
function LoserCutMovePrice() { return 2.5; }
function NormalizePriceForDirection(value) { return value; }
function SymbolInfoDouble(_symbol, property) {
  if (property === SYMBOL_MARGIN_HEDGED) return marginHedged;
  return property === SYMBOL_BID ? bid : ask;
}
function AccountInfoDouble(property) {
  return property === ACCOUNT_EQUITY ? equity : usedMargin;
}
function OrderCalcMargin(_type, _symbol, volume, _price) {
  if (calcMarginFails) return { ok: false, margin: 0 };
  return { ok: true, margin: volume * marginPerLot };
}
function NormalizeVolumeDown(requestedLot) {
  return requestedLot >= volumeMin ? Math.round(requestedLot * 100) / 100 : 0;
}
function VolumeDigits() { return 2; }
function ResetLastError() {}
function GetLastError() { return 0; }
function MathMax(a, b) { return Math.max(a, b); }
function MathMin(a, b) { return Math.min(a, b); }
function ArraySize(array) { return array.length; }
function ArrayRemove(array, index, count) { array.splice(index, count); }
function SavePersistentState() { saves += 1; }
function BasketHasPendingOrders() { return live.pendingBuy + live.pendingSell > 0; }
function BasketHasOpenState() {
  return live.buys + live.sells + live.pendingBuy + live.pendingSell > 0;
}
function DeleteBasketPendingOrders() {
  pendingDeletes += 1;
  if (pendingDeleteSucceeds) { live.pendingBuy = 0; live.pendingSell = 0; }
}
function CloseBasketAtMarket() {
  basketCloses += 1;
  if (basketCloseSucceeds) {
    live.buys = 0; live.sells = 0; live.pendingBuy = 0; live.pendingSell = 0;
  }
}
function SideHasOpenState(_basket, direction) {
  return direction === 1
    ? live.buys + live.pendingBuy > 0
    : live.sells + live.pendingSell > 0;
}
function CloseSideAtMarket(_basket, direction) {
  sideCloses += 1;
  if (!sideCloseSucceeds) return;
  if (direction === 1) {
    live.buys = 0; live.buyLosers = 0; live.buyAdvance = 0; live.pendingBuy = 0;
  } else {
    live.sells = 0; live.sellLosers = 0; live.sellAdvance = 0; live.pendingSell = 0;
  }
}
function GetBasketStats() {
  statsReads += 1;
  return {
    buyCount: live.buys,
    sellCount: live.sells,
    buyAdvance: live.buyAdvance,
    sellAdvance: live.sellAdvance,
    netProfit: live.buyAdvance + live.sellAdvance,
    buyLosingCount: live.buyLosers,
    sellLosingCount: live.sellLosers,
  };
}
function GetTrailingAnchors(_basket, direction) {
  const buy = direction === 1;
  return {
    ok: (buy ? live.buys : live.sells) > 0 && (buy ? live.newestBuy : live.newestSell) > 0,
    newestEntry: buy ? live.newestBuy : live.newestSell,
    previousEntry: buy ? live.previousBuy : live.previousSell,
  };
}
function ApplyBasketProtection() { applies += 1; }
function ApplyFailsafeStop(_basket, direction = 0) { failsafeApplies += 1; failsafeDirection = direction; }
function HistoryDealSelect() { return true; }
function HistoryDealGetString() { return deal.symbol; }
function HistoryDealGetInteger(_ticket, property) {
  if (property === DEAL_ENTRY) return deal.entry;
  if (property === DEAL_REASON) return deal.reason;
  if (property === DEAL_TYPE) return deal.type;
  return deal.positionId;
}
function HistoryDealGetDouble(_ticket, property) { return property === DEAL_SL ? deal.sl : deal.tp; }
function HistoryOrderSelect() { return deal.openingOrderAvailable; }
function HistoryOrderGetString(_ticket, property) {
  return property === ORDER_SYMBOL ? deal.openingSymbol : deal.tag;
}
function HistoryOrderGetInteger() { return deal.magic; }
function RootTicketFromComment(comment) { return comment === 'G#100' ? 100 : 999; }

// Evaluate only the transformed production functions in this mocked scope.
eval(productionFunctions);

let passed = 0;
function test(name, body) {
  try {
    body();
    passed += 1;
  } catch (error) {
    error.message = `${name}: ${error.message}`;
    throw error;
  }
}
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

for (const direction of [1, -1]) {
  test(`protective touch latches and retries direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.protectionArmed = true;
    basket.protectionDirection = direction;
    basket.protectionPrice = 4005;
    if (direction === 1) { bid = 4005; ask = 4005.2; }
    else { bid = 4004.8; ask = 4005; }
    ManageFormulaClose();
    assert(basket.marketExitRequested && saves === 1 && basketCloses === 1, 'touch did not persist full exit');
    bid = direction === 1 ? 4010 : 4000;
    ask = bid + 0.2;
    ManageFormulaClose();
    assert(basketCloses === 2 && applies === 0, 'bounce cancelled latched retry');
    basketCloseSucceeds = true;
    ManageFormulaClose();
    assert(g_closeBaskets.length === 0, 'completed retry did not retire basket');
  });

  test(`invalid quote cannot touch direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.protectionArmed = true;
    basket.protectionDirection = direction;
    basket.protectionPrice = 4005;
    assert(!ProtectionLineTouched(basket, 0, 4005), 'invalid quote triggered line');
  });

  test(`failsafe stop runs only while a settled exit keeps failing direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.marketExitRequested = true;
    ManageFormulaClose();
    assert(basketCloses === 1 && failsafeApplies === 1,
      'failsafe stop did not run while the settled exit kept failing');
    ManageFormulaClose();
    assert(basketCloses === 2 && failsafeApplies === 2,
      'failsafe stop did not keep running on repeated retries');
    basketCloseSucceeds = true;
    ManageFormulaClose();
    assert(g_closeBaskets.length === 0 && failsafeApplies === 2,
      'failsafe stop ran again after the exit finally succeeded');
  });

  test(`failed winner cut suppresses ordinary trailing direction ${direction}`, () => {
    reset(direction);
    ManageFormulaClose();
    assert(sideCloses === 1 && applies === 0 && statsReads === 2, 'post-cut ordinary trailing was not suppressed');
    assert(g_closeBaskets[0].winnerCutDirection === direction, 'winner direction was not banked');
    ManageFormulaClose();
    assert(sideCloses === 2 && applies === 0, 'retry created protection before recovery arm');
  });

  test(`failsafe stop protects the cut side while its close keeps failing direction ${direction}`, () => {
    reset(direction);
    ManageFormulaClose();
    assert(sideCloses === 1 && failsafeApplies === 1 && failsafeDirection === -direction,
      'failsafe stop did not guard the cut side after the first failed close');
    ManageFormulaClose();
    assert(sideCloses === 2 && failsafeApplies === 2 && failsafeDirection === -direction,
      'failsafe stop did not keep guarding the cut side on retry');
    sideCloseSucceeds = true;
    ManageFormulaClose();
    assert(sideCloses === 3 && failsafeApplies === 2,
      'failsafe stop ran again after the cut side finally closed');
  });

  test(`failed winner retry still enforces budget direction ${direction}`, () => {
    reset(direction);
    ManageFormulaClose();
    bid = direction === 1 ? 4009 : 4005.8;
    ask = bid + 0.2;
    ManageFormulaClose();
    assert(g_closeBaskets[0].marketExitRequested && basketCloses === 1, 'retry starved unchanged budget');
  });

  test(`successful winner cut protects same tick direction ${direction}`, () => {
    reset(direction);
    sideCloseSucceeds = true;
    if (direction === 1) { bid = 4008; ask = 4008.2; }
    else { bid = 4006.8; ask = 4007; }
    ManageFormulaClose();
    assert(applies === 1 && statsReads === 2, 'exact recovery threshold skipped same-tick protection');
    assert(g_closeBaskets[0].recoverySLArmed, 'recovery SL was not armed');
    assert(direction === 1 ? live.sells === 0 : live.buys === 0, 'cut side survived successful close');
  });

  test(`actual trailing ratchet is persisted direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.protectionArmed = true;
    basket.protectionDirection = direction;
    basket.protectionPrice = direction === 1 ? 4002 : 4013;
    UpdateTrailingProtection(basket, direction);
    assert(saves === 1, 'changed protection line was not persisted');
    const ratcheted = basket.protectionPrice;
    UpdateTrailingProtection(basket, direction);
    assert(saves === 1 && basket.protectionPrice === ratcheted, 'unchanged line wrote persistent state');
  });

  test(`clean trail retires pending and follows price direction ${direction}`, () => {
    reset(direction);
    Object.assign(live, direction === 1
      ? { buys: 2, sells: 0, buyAdvance: 10, sellAdvance: 0, buyLosers: 0, sellLosers: 0 }
      : { buys: 0, sells: 2, buyAdvance: 0, sellAdvance: 10, buyLosers: 0, sellLosers: 0 });
    pendingDeleteSucceeds = false;
    ManageFormulaClose();
    const basket = g_closeBaskets[0];
    assert(basket.cleanTrailActive && basket.protectionDirection === direction, 'clean decision/direction was not latched');
    assert(pendingDeletes === 1 && live.pendingBuy + live.pendingSell === 2, 'first pending delete attempt was not made');
    const firstLine = basket.protectionPrice;
    if (direction === 1) { bid += 1; ask += 1; }
    else { bid -= 1; ask -= 1; }
    ManageFormulaClose();
    assert(pendingDeletes === 2 && applies === 2, 'failed pending delete stopped clean management');
    assert(IsBetterLine(basket.protectionPrice, firstLine, direction), 'clean line did not follow favorable quote');
    assert(MathAbs(basket.protectionPrice - ((direction === 1 ? bid : ask) - direction * TrailArmPrice())) < 1e-9,
      'clean line did not keep the configured quote distance');
    pendingDeleteSucceeds = true;
    ManageFormulaClose();
    assert(live.pendingBuy + live.pendingSell === 0, 'pending retirement was not retried to completion');
  });
}

for (const direction of [1, -1]) {
  for (const k of [1, 2]) {
    test(`recovery k${k} arms exactly at threshold direction ${direction}`, () => {
      reset(direction);
      const basket = g_closeBaskets[0];
      basket.winnerCutDirection = direction;
      basket.winnerCutAnchorPrice = 4006;
      basket.bankedLoserCount = k;
      const expectedStop = 4006 + direction * (k - 1) * 3;
      const trigger = expectedStop + direction * 2;
      assert(MathAbs(RecoveryStopPrice(basket) - expectedStop) < 1e-9, 'fixed recovery stop formula changed');
      if (direction === 1) { bid = trigger - 0.001; ask = bid + 0.2; }
      else { ask = trigger + 0.001; bid = ask - 0.2; }
      UpdateRecoveryProtection(basket);
      assert(!basket.recoverySLArmed && !basket.protectionArmed && saves === 0, 'recovery armed before threshold');
      if (direction === 1) { bid = trigger; ask = bid + 0.2; }
      else { ask = trigger; bid = ask - 0.2; }
      UpdateRecoveryProtection(basket);
      assert(basket.recoverySLArmed && basket.protectionArmed, 'recovery did not arm at exact threshold');
      assert(basket.protectionPrice === expectedStop && saves === 1, 'wrong fixed recovery line or persistence');
    });

    test(`recovery k${k} budget exits at exact limit direction ${direction}`, () => {
      reset(direction);
      const basket = g_closeBaskets[0];
      basket.winnerCutDirection = direction;
      basket.winnerCutAnchorPrice = 4006;
      basket.bankedLoserCount = k;
      Object.assign(live, direction === 1
        ? { buys: 3, sells: 0, buyAdvance: 20, sellAdvance: 0, buyLosers: 0, sellLosers: 0, pendingBuy: 0, pendingSell: 0 }
        : { buys: 0, sells: 3, buyAdvance: 0, sellAdvance: 20, buyLosers: 0, sellLosers: 0, pendingBuy: 0, pendingSell: 0 });
      const budget = 4006 + direction * k * 3;
      if (direction === 1) { bid = budget; ask = bid + 0.2; }
      else { ask = budget; bid = ask - 0.2; }
      ManageFormulaClose();
      assert(basket.marketExitRequested && basketCloses === 1, 'budget did not market-exit at exact limit');
      assert(!basket.recoverySLArmed, 'budget must pre-empt recovery arming');
    });

    test(`K trailing matches the ordinary ladder before the recovery stop, k${k} direction ${direction}`, () => {
      reset(direction);
      const basket = g_closeBaskets[0];
      basket.winnerCutDirection = direction;
      basket.winnerCutAnchorPrice = 4006;
      basket.bankedLoserCount = k;
      const recoveryStop = 4006 + direction * (k - 1) * 3;
      if (direction === 1) { bid = recoveryStop - 1; ask = bid + 0.2; }
      else { ask = recoveryStop + 1; bid = ask - 0.2; }
      UpdateTrailingProtection(basket, direction);

      const ordinary = newBasket();
      UpdateTrailingProtection(ordinary, direction);
      assert(MathAbs(basket.protectionPrice - ordinary.protectionPrice) < 1e-9,
        'K-mode trailed tighter than the no-cut ladder before reaching the recovery stop');
    });

    test(`K trailing improves on the ladder past the recovery stop, k${k} direction ${direction}`, () => {
      reset(direction);
      const basket = g_closeBaskets[0];
      basket.winnerCutDirection = direction;
      basket.winnerCutAnchorPrice = 4006;
      basket.bankedLoserCount = k;
      const recoveryStop = 4006 + direction * (k - 1) * 3;
      if (direction === 1) { bid = recoveryStop + 1; ask = bid + 0.2; }
      else { ask = recoveryStop - 1; bid = ask - 0.2; }
      UpdateTrailingProtection(basket, direction);

      const ordinary = newBasket();
      UpdateTrailingProtection(ordinary, direction);
      assert(IsBetterLine(basket.protectionPrice, ordinary.protectionPrice, direction),
        'K-mode price-following did not improve on the plain ladder past the recovery stop');
    });
  }

  test(`recovery keeps tighter existing line direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.winnerCutDirection = direction;
    basket.winnerCutAnchorPrice = 4006;
    basket.bankedLoserCount = 1;
    basket.protectionArmed = true;
    basket.protectionDirection = direction;
    basket.protectionPrice = 4006 + direction * 0.5;
    if (direction === 1) { bid = 4008; ask = 4008.2; }
    else { ask = 4004; bid = 4003.8; }
    UpdateRecoveryProtection(basket);
    assert(basket.recoverySLArmed && basket.protectionPrice === 4006 + direction * 0.5,
      'recovery loosened an existing formula protection line');
  });

  test(`armed recovery line stays fixed direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.winnerCutDirection = direction;
    basket.winnerCutAnchorPrice = 4006;
    basket.bankedLoserCount = 2;
    basket.recoverySLArmed = true;
    basket.protectionArmed = true;
    basket.protectionDirection = direction;
    basket.protectionPrice = 4006 + direction * 3;
    if (direction === 1) { bid = 4011.5; ask = 4011.7; }
    else { ask = 4000.5; bid = 4000.3; }
    UpdateRecoveryProtection(basket);
    assert(basket.protectionPrice === 4006 + direction * 3 && saves === 0,
      'armed recovery SL trailed with price');
  });

  test(`recovery captures opposite-direction prior line direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.winnerCutDirection = direction;
    basket.winnerCutAnchorPrice = 4006;
    basket.bankedLoserCount = 1;
    basket.protectionArmed = true;
    basket.protectionDirection = -direction;
    basket.protectionPrice = direction === 1 ? 4010 : 4002;
    const oldPrice = basket.protectionPrice;
    if (direction === 1) { bid = 4008; ask = 4008.2; }
    else { ask = 4004; bid = 4003.8; }
    UpdateRecoveryProtection(basket);
    assert(basket.recoverySLArmed && basket.protectionDirection === direction && basket.protectionPrice === 4006,
      'recovery current line/direction was not installed');
    assert(basket.retainedProtectionDirection === -direction && basket.retainedProtectionPrice === oldPrice,
      'prior formula line was not retained for delayed broker execution');
  });

  // The cut distance is below one grid step and the survivor's ladder line
  // sits a full step back, so a live loser cut on that side would always
  // fire first - closing the very recovery the winner cut paid for. The
  // survivor is therefore exempt from the moment of the cut, not from the
  // later recovery-SL arming.
  for (const armed of [false, true]) {
    test(`winner-cut survivor is exempt from the loser cut ${armed ? 'after' : 'before'} the recovery SL arms direction ${direction}`, () => {
      reset(direction);
      const basket = g_closeBaskets[0];
      basket.winnerCutDirection = direction;
      basket.winnerCutAnchorPrice = 4006;
      basket.bankedLoserCount = 2;
      basket.recoverySLArmed = armed;
      basket.protectionArmed = armed;
      basket.protectionDirection = direction;
      basket.protectionPrice = 4006 + direction * 3;
      InpMaxLosersBeforeCut = 2;
      Object.assign(live, direction === 1
        ? { buys: 3, sells: 0, buyAdvance: 10, sellAdvance: 0, buyLosers: 0, sellLosers: 0,
            pendingBuy: 0, pendingSell: 0, newestBuy: 4012, previousBuy: 4009 }
        : { buys: 0, sells: 3, buyAdvance: 0, sellAdvance: 10, buyLosers: 0, sellLosers: 0,
            pendingBuy: 0, pendingSell: 0, newestSell: 4000, previousSell: 4003 });
      if (direction === 1) { bid = 4009.4; ask = 4009.6; }
      else { ask = 4002.6; bid = 4002.4; }
      ManageFormulaClose();
      assert(!basket.marketExitRequested,
        'the loser cut closed the survivor the winner cut paid for');
    });
  }

  test(`a basket that never cut still takes the loser cut direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    InpMaxLosersBeforeCut = 2;
    Object.assign(live, direction === 1
      ? { buys: 2, sells: 1, buyAdvance: 10, sellAdvance: -1, buyLosers: 0, sellLosers: 0,
          pendingBuy: 0, pendingSell: 0, newestBuy: 4012, previousBuy: 4009 }
      : { buys: 1, sells: 2, buyAdvance: -1, sellAdvance: 10, buyLosers: 0, sellLosers: 0,
          pendingBuy: 0, pendingSell: 0, newestSell: 4000, previousSell: 4003 });
    if (direction === 1) { bid = 4009.4; ask = 4009.6; }
    else { ask = 4002.6; bid = 4002.4; }
    ManageFormulaClose();
    assert(basket.marketExitRequested,
      'the loser cut stopped working on an ordinary mixed basket');
  });

  test(`armed recovery still guards opposite side direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.winnerCutDirection = direction;
    basket.winnerCutAnchorPrice = 4006;
    basket.bankedLoserCount = 1;
    basket.recoverySLArmed = true;
    basket.protectionArmed = true;
    basket.protectionDirection = direction;
    basket.protectionPrice = 4006;
    InpMaxLosersBeforeCut = 2;
    Object.assign(live, direction === 1
      ? { buys: 3, sells: 2, buyAdvance: 10, sellAdvance: -2, buyLosers: 0, sellLosers: 0,
          pendingBuy: 0, pendingSell: 0, newestBuy: 4009, previousBuy: 4006,
          newestSell: 4004, previousSell: 4001 }
      : { buys: 2, sells: 3, buyAdvance: -2, sellAdvance: 10, buyLosers: 0, sellLosers: 0,
          pendingBuy: 0, pendingSell: 0, newestBuy: 4006, previousBuy: 4009,
          newestSell: 4003, previousSell: 4006 });
    if (direction === 1) { bid = 4006.4; ask = 4006.6; }
    else { bid = 4003.4; ask = 4003.6; }
    ManageFormulaClose();
    assert(basket.marketExitRequested, 'armed recovery incorrectly disabled opposite-side loser cut');
  });

  test(`clean trail direction bypasses legacy loser cut direction ${direction}`, () => {
    reset(direction);
    const basket = g_closeBaskets[0];
    basket.cleanTrailActive = true;
    basket.protectionArmed = true;
    basket.protectionDirection = direction;
    basket.protectionPrice = direction === 1 ? 4006 : 4003;
    InpMaxLosersBeforeCut = 2;
    Object.assign(live, direction === 1
      ? { buys: 2, sells: 0, buyAdvance: 5, sellAdvance: 0, buyLosers: 0, sellLosers: 0,
          pendingBuy: 0, pendingSell: 0, newestBuy: 4009, previousBuy: 4006 }
      : { buys: 0, sells: 2, buyAdvance: 0, sellAdvance: 5, buyLosers: 0, sellLosers: 0,
          pendingBuy: 0, pendingSell: 0, newestSell: 4000, previousSell: 4003 });
    if (direction === 1) { bid = 4006.4; ask = 4006.6; }
    else { ask = 4002.6; bid = 4002.4; }
    ManageFormulaClose();
    assert(!basket.marketExitRequested && applies === 1, 'legacy loser cut pre-empted clean trailing');
  });
}

for (const direction of [1, -1]) {
  for (const trigger of ['winning-sl', 'losing-tp']) {
    test(`owned broker ${trigger} latches direction ${direction}`, () => {
      reset();
      const basket = g_closeBaskets[0];
      basket.protectionArmed = true;
      basket.protectionDirection = direction;
      basket.protectionPrice = 4003.05;
      const positionDirection = trigger === 'winning-sl' ? direction : -direction;
      deal.reason = trigger === 'winning-sl' ? DEAL_REASON_SL : DEAL_REASON_TP;
      deal.type = positionDirection === 1 ? DEAL_TYPE_SELL : DEAL_TYPE_BUY;
      deal.positionId = trigger === 'winning-sl' ? basket.manualPositionId : 202;
      ProcessProtectionExitDeal(1);
      assert(basket.marketExitRequested && basketCloses === 1 && saves === 1, 'owned protective deal was ignored');
    });
  }
}

for (const currentDirection of [1, -1]) {
  for (const retainedRole of ['winning-sl', 'losing-tp']) {
    test(`restored retained ${retainedRole} matches old direction ${-currentDirection}`, () => {
      reset();
      const basket = g_closeBaskets[0];
      basket.protectionArmed = true;
      basket.protectionDirection = currentDirection;
      basket.protectionPrice = 4006;
      basket.recoverySLArmed = true;
      basket.retainedProtectionDirection = -currentDirection;
      basket.retainedProtectionPrice = currentDirection === 1 ? 4010 : 4002;
      const positionDirection = retainedRole === 'winning-sl'
        ? basket.retainedProtectionDirection
        : -basket.retainedProtectionDirection;
      deal.reason = retainedRole === 'winning-sl' ? DEAL_REASON_SL : DEAL_REASON_TP;
      deal.type = positionDirection === 1 ? DEAL_TYPE_SELL : DEAL_TYPE_BUY;
      deal.positionId = positionDirection === currentDirection ? basket.manualPositionId : 202;
      deal.sl = basket.retainedProtectionPrice;
      deal.tp = basket.retainedProtectionPrice;
      ProcessProtectionExitDeal(1);
      assert(basket.marketExitRequested && basketCloses === 1, 'retained broker line was not attributed');
    });
  }

  test(`retained line rejects wrong exit role direction ${currentDirection}`, () => {
    reset();
    const basket = g_closeBaskets[0];
    basket.protectionArmed = true;
    basket.protectionDirection = currentDirection;
    basket.protectionPrice = 4006;
    basket.recoverySLArmed = true;
    basket.retainedProtectionDirection = -currentDirection;
    basket.retainedProtectionPrice = currentDirection === 1 ? 4010 : 4002;
    const positionDirection = currentDirection;
    deal.reason = DEAL_REASON_SL;
    deal.type = positionDirection === 1 ? DEAL_TYPE_SELL : DEAL_TYPE_BUY;
    deal.positionId = basket.manualPositionId;
    deal.sl = basket.retainedProtectionPrice;
    ProcessProtectionExitDeal(1);
    assert(!basket.marketExitRequested && basketCloses === 0, 'retained line accepted unrelated SL role');
  });
}

const ignoredDealCases = [
  ['foreign symbol', () => { deal.symbol = 'EURUSD'; }],
  ['foreign basket', () => { deal.positionId = 202; deal.tag = 'G#999'; }],
  ['non SL/TP reason', () => { deal.reason = DEAL_REASON_EXPERT; }],
  ['tighter unrelated optional SL', () => { deal.sl = 4004; }],
  ['entry deal', () => { deal.entry = DEAL_ENTRY_IN; }],
  ['disabled formula master', () => { InpUseFormulaClose = false; }],
  ['missing opening order ownership', () => { deal.positionId = 202; deal.openingOrderAvailable = false; }],
];
for (const [name, arrange] of ignoredDealCases) {
  test(`ignores ${name}`, () => {
    reset();
    const basket = g_closeBaskets[0];
    basket.protectionArmed = true;
    basket.protectionDirection = 1;
    basket.protectionPrice = 4003.05;
    arrange();
    ProcessProtectionExitDeal(1);
    assert(!basket.marketExitRequested && basketCloses === 0, 'unrelated deal triggered basket exit');
  });
}

function near(actual, expected) {
  return Math.abs(actual - expected) < 1e-9;
}

// Grid at these defaults: same side levels 2..5 = 0.03+0.05+0.07+0.09 = 0.24
// lot, opposite side levels 1..5 = manual 0.02 + 0.24 = 0.26 lot. At 400 per
// lot that is 96 and 104 units of margin.
const MANUAL_LOT = 0.02;

test('level 1 mirrors the manual lot', () => {
  reset();
  assert(near(LotForLevel(1, MANUAL_LOT), MANUAL_LOT), 'level 1 did not mirror the manual lot');
});

test('level 2+ follows the odd multiples of the fixed unit', () => {
  reset();
  assert(near(LotForLevel(2, MANUAL_LOT), 0.03) &&
         near(LotForLevel(3, MANUAL_LOT), 0.05) &&
         near(LotForLevel(5, MANUAL_LOT), 0.09),
         'fixed lot progression is not 3,5,...,9 units');
});

test('a level below the broker minimum costs no margin', () => {
  reset();
  assert(LevelMargin(1, 4000, 0.005) === 0, 'an unplaceable level was still budgeted for');
});

test('a priced level costs volume times the broker rate', () => {
  reset();
  assert(near(LevelMargin(1, 4000, 0.05), 20), 'level margin did not follow the broker rate');
});

test('an uncalculable level reports failure', () => {
  reset();
  calcMarginFails = true;
  assert(LevelMargin(1, 4000, 0.05) < 0, 'a failed margin calculation was not reported');
});

test('a comfortable account accepts the grid', () => {
  reset();
  assert(GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'a well funded grid was rejected');
});

test('a thin account rejects the grid', () => {
  reset();
  equity = 300;   // 300 / 104 = 288% against a 300% floor
  assert(!GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'an underfunded grid was accepted');
});

test('the floor is inclusive', () => {
  reset();
  equity = 312;   // 312 / 104 = exactly 300%
  assert(GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'a grid exactly at the floor was rejected');
});

test('free hedged volume budgets only the dearer side', () => {
  reset();
  marginHedged = 0;
  equity = 500;   // 500 / 104 = 481% one side, 500 / 200 = 250% both
  assert(GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'hedged netting was not credited');
});

test('charged hedged volume budgets both sides', () => {
  reset();
  marginHedged = 5;
  equity = 500;
  assert(!GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'both sides were not summed when hedging costs margin');
});

test('margin already in use counts against the floor', () => {
  reset();
  equity = 500;
  usedMargin = 100;   // 500 / 204 = 245%
  assert(!GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'existing exposure was ignored');
});

test('an uncalculable level rejects the whole grid', () => {
  reset();
  calcMarginFails = true;
  assert(!GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'a grid that cannot be priced was accepted');
});

test('non-positive equity rejects the grid', () => {
  reset();
  equity = 0;
  assert(!GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'a grid was accepted without readable equity');
});

test('a zero floor disables the margin guard', () => {
  reset();
  InpMinMarginLevelPercent = 0;
  equity = 1;
  assert(GridMarginIsAffordable(1, 4000, MANUAL_LOT, 0, 0), 'the disabled guard still rejected a grid');
});

// Queued grid: entry 4000, window expiring at 10000 on a clock reading 5000.
test('a queued grid survives inside the window and near the entry', () => {
  reset();
  assert(PendingGridStillValid(4000, 1, 10000, 4000.4, 4000.6, 5000),
         'a retryable grid was abandoned');
});

test('a queued grid expires with its window', () => {
  reset();
  assert(!PendingGridStillValid(4000, 1, 10000, 4000.4, 4000.6, 10000),
         'the retry window is not inclusive at its end');
});

test('a queued grid is abandoned once price walks a full grid step', () => {
  reset();
  assert(!PendingGridStillValid(4000, 1, 10000, 4002.9, 4003.1, 5000),
         'a grid was retried after price left the entry it was built around');
  assert(PendingGridStillValid(4000, 1, 10000, 4002.7, 4002.9, 5000),
         'a grid still inside one step was abandoned');
});

test('a queued grid measures drift against its own side', () => {
  reset();
  // A Sell entry is chased by Bid, so an Ask that has drifted must not end it.
  assert(PendingGridStillValid(4000, -1, 10000, 3997.2, 4003.5, 5000),
         'drift was measured against the wrong side of the quote');
});

test('a queued grid waits out an unreadable quote', () => {
  reset();
  assert(PendingGridStillValid(4000, 1, 10000, 0, 0, 5000),
         'a missing quote ended the retry instead of the window');
});

test('an unfiltered manual entry is accepted', () => {
  reset();
  assert(ManualEntryAccepted(MANUAL_LOT), 'the default filter rejected a manual entry');
});

test('a manual entry below the lot filter is ignored', () => {
  reset();
  InpMinManualLot = 0.05;
  assert(!ManualEntryAccepted(MANUAL_LOT), 'an undersized manual entry was gridded');
});

test('a manual entry above the lot filter is ignored', () => {
  reset();
  InpMaxManualLot = 0.01;
  assert(!ManualEntryAccepted(MANUAL_LOT), 'an oversized manual entry was gridded');
});

test('the concurrent basket cap blocks a new manual entry', () => {
  reset();   // reset() leaves exactly one basket running
  InpMaxConcurrentBaskets = 1;
  assert(!ManualEntryAccepted(MANUAL_LOT), 'the basket cap did not hold');
});

test('room under the concurrent cap still accepts', () => {
  reset();
  InpMaxConcurrentBaskets = 2;
  assert(ManualEntryAccepted(MANUAL_LOT), 'the basket cap rejected an entry that fits');
});

console.log(`PASS: ${passed} deterministic exit and grid-placement scenarios using extracted EA functions and mocked broker state`);
