// Deterministic behavior checks against functions extracted from the production MQL5 EA.
// These mocks verify configured exit transitions; they do not emulate MT5 fills.
const fs = require('node:fs');
const path = require('node:path');

const sourcePath = path.join(__dirname, '..', 'Experts', 'XAUUSD_StopGrid_9x9_EA.mq5');
const source = fs.readFileSync(sourcePath, 'utf8');
const functionNames = [
  'OnTradeTransaction',
  'CountOwnPositionsByDirection',
  'EvaluateThirdLevelCase',
  'ManageGridExitRules',
  'DetectThirdLevelDirection',
  'DetectFifthLevelDirection',
  'ActivateConfiguredCase',
  'ConfiguredCaseTargetLevel',
  'ConfiguredCaseStopLevel',
  'FixedCaseName',
  'HasOwnPositionAtLevel',
  'ManageConfiguredCase',
  'AllMainPositionsHaveCaseTakeProfit',
  'SetConfiguredCaseTakeProfit',
  'SetConfiguredCaseStopLoss',
  'RetryCloseCaseBasket',
  'ActivateTrailing',
  'ManageTrailingStops',
  'ClosePositionsByDirection',
  'DeleteAllOwnPending',
  'CountOwnPendingOrders',
  'TradeResultAccepted',
];

function extractFunction(name) {
  const header = new RegExp(`^(?:void|int|bool|double|string) ${name}\\([^)]*\\)\\s*\\{`, 'm').exec(source);
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

function transformFunction(name, original) {
  let code = original.replace(
    new RegExp(`^(?:void|int|bool|double|string) ${name}\\(([^)]*)\\)\\s*\\{`),
    (_match, rawParams) => {
      const params = rawParams.split(',').map((param) =>
        param.trim().replace(/^(?:const\s+)?[A-Za-z_][A-Za-z0-9_]*\s*&?\s*/, ''),
      );
      return `function ${name}(${params.join(', ')}) {`;
    },
  );

  code = code.replace(
    /MqlTick tick;\s*if\(!SymbolInfoTick\(_Symbol, tick\) \|\| tick\.ask <= 0\.0 \|\| tick\.bid <= 0\.0\)\s*return;/,
    'let tick = SymbolInfoTick(_Symbol); if(!tick || tick.ask <= 0.0 || tick.bid <= 0.0) return;',
  );
  code = code
    .replace(/\((?:ENUM_DEAL_ENTRY|ENUM_POSITION_TYPE|ulong|uint|long|int|double|datetime)\)/g, '')
    .replace(/\b(?:double|int|bool|string|ulong|uint|long|datetime|ENUM_POSITION_TYPE|ENUM_DEAL_ENTRY)\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*;/g, 'let $1;')
    .replace(/\b(?:double|int|bool|string|ulong|uint|long|datetime|ENUM_POSITION_TYPE|ENUM_DEAL_ENTRY)\s+([A-Za-z_]\w*)\s*=/g, 'let $1 =')
    .replace(/for\(int\s+/g, 'for(let ');
  return code;
}

const productionFunctions = functionNames
  .map((name) => transformFunction(name, extractFunction(name)))
  .join('\n\n');

const TRADE_TRANSACTION_DEAL_ADD = 1;
const DEAL_MAGIC = 'dealMagic';
const DEAL_ENTRY = 'dealEntry';
const DEAL_ORDER = 'dealOrder';
const DEAL_ENTRY_IN = 1;
const DEAL_TYPE_BUY = 1;
const DEAL_TYPE_SELL = 2;
const ORDER_COMMENT = 'orderComment';
const ORDER_SYMBOL = 'orderSymbol';
const ORDER_MAGIC = 'orderMagic';
const POSITION_SYMBOL = 'positionSymbol';
const POSITION_COMMENT = 'positionComment';
const POSITION_MAGIC = 'positionMagic';
const POSITION_TYPE = 'positionType';
const POSITION_TIME = 'positionTime';
const POSITION_SL = 'positionSL';
const POSITION_TP = 'positionTP';
const POSITION_TYPE_BUY = 1;
const POSITION_TYPE_SELL = 2;
const TRAIL_ACTIVATION_LEVEL = 3;
const TRAIL_STEP_PRICE = 1.0;
const TRADE_RETCODE_DONE = 10009;
const TRADE_RETCODE_DONE_PARTIAL = 10010;
const TRADE_RETCODE_PLACED = 10008;

let _Symbol;
let _Digits;
let InpMagicNumber;
let InpGridStepPrice;
let InpRetrySeconds;
let g_anchorPrice;
let g_tickSize;
let g_stateKey;
let g_trailingDirection;
let g_level3Evaluated;
let g_fixedCaseId;
let g_fixedCaseDirection;
let g_fixedCaseCloseRetryAfter;
let positions;
let orders;
let tick;
let activeDeal;
let selectedPosition;
let selectedOrder;
let globals;
let logs;
let currentTime;
let positionCloseAttempts;
let allowPositionClose;

const trade = {
  retcode: TRADE_RETCODE_DONE,
  OrderDelete(ticket) {
    orders = orders.filter((order) => order.ticket !== ticket);
    this.retcode = TRADE_RETCODE_DONE;
    return true;
  },
  PositionModify(ticket, sl, tp) {
    const position = positions.find((candidate) => candidate.ticket === ticket);
    if (!position) return false;
    position.sl = sl;
    position.tp = tp;
    this.retcode = TRADE_RETCODE_DONE;
    return true;
  },
  PositionClose(ticket) {
    positionCloseAttempts += 1;
    if (!allowPositionClose) {
      this.retcode = 10018;
      return false;
    }
    positions = positions.filter((position) => position.ticket !== ticket);
    this.retcode = TRADE_RETCODE_DONE;
    return true;
  },
  ResultRetcode() { return this.retcode; },
  ResultRetcodeDescription() { return 'done'; },
};

function reset({ direction = 1, same = 3, opposite = 0 } = {}) {
  _Symbol = 'XAUUSD';
  _Digits = 3;
  InpMagicNumber = 20260925;
  InpGridStepPrice = 2.0;
  InpRetrySeconds = 30;
  g_anchorPrice = 4000.0;
  g_tickSize = 0.001;
  g_stateKey = 'SG9.test';
  g_trailingDirection = 0;
  g_level3Evaluated = false;
  g_fixedCaseId = 0;
  g_fixedCaseDirection = 0;
  g_fixedCaseCloseRetryAfter = 0;
  tick = direction > 0
    ? { bid: 4006.0, ask: 4006.2 }
    : { bid: 3994.0, ask: 3994.2 };
  globals = {};
  logs = [];
  currentTime = 1000;
  positionCloseAttempts = 0;
  allowPositionClose = true;
  selectedPosition = null;
  selectedOrder = null;

  positions = [];
  for (let index = 1; index <= same; index++) {
    const level = index;
    const type = direction > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
    positions.push({
      ticket: index,
      symbol: _Symbol,
      magic: InpMagicNumber,
      type,
      time: index,
      comment: `SG9|${direction > 0 ? 'B' : 'S'}|L${String(level).padStart(2, '0')}`,
      sl: g_anchorPrice,
      tp: g_anchorPrice + direction * 20.0,
    });
  }
  for (let index = 1; index <= opposite; index++) {
    positions.push({
      ticket: 100 + index,
      symbol: _Symbol,
      magic: InpMagicNumber,
      type: direction > 0 ? POSITION_TYPE_SELL : POSITION_TYPE_BUY,
      time: 100 + index,
      comment: `SG9|${direction > 0 ? 'S' : 'B'}|L${String(index).padStart(2, '0')}`,
      sl: g_anchorPrice,
      tp: g_anchorPrice - direction * 20.0,
    });
  }
  orders = [];
  let ticket = 1000;
  for (const side of ['B', 'S']) {
    for (let level = 1; level <= 9; level++) {
      orders.push({ ticket: ticket++, symbol: _Symbol, magic: InpMagicNumber,
        type: side === 'B' ? 'buy-stop' : 'sell-stop', comment: `SG9|${side}|L${String(level).padStart(2, '0')}` });
    }
  }
  orders.push({ ticket: 9999, symbol: 'EURUSD', magic: InpMagicNumber, type: 'buy-stop', comment: 'unrelated' });
  activeDeal = {
    magic: InpMagicNumber,
    entry: DEAL_ENTRY_IN,
    order: 1003,
    comment: `SG9|${direction > 0 ? 'B' : 'S'}|L03`,
  };
}

function PositionsTotal() { return positions.length; }
function PositionGetTicket(index) {
  selectedPosition = positions[index];
  return selectedPosition ? selectedPosition.ticket : 0;
}
function PositionGetString(property) {
  if (property === POSITION_SYMBOL) return selectedPosition.symbol;
  if (property === POSITION_COMMENT) return selectedPosition.comment;
  return '';
}
function PositionGetInteger(property) {
  if (property === POSITION_MAGIC) return selectedPosition.magic;
  if (property === POSITION_TYPE) return selectedPosition.type;
  if (property === POSITION_TIME) return selectedPosition.time || 0;
  return 0;
}
function PositionGetDouble(property) {
  if (property === POSITION_SL) return selectedPosition.sl;
  if (property === POSITION_TP) return selectedPosition.tp;
  return 0;
}
function OrdersTotal() { return orders.length; }
function OrderGetTicket(index) {
  selectedOrder = orders[index];
  return selectedOrder ? selectedOrder.ticket : 0;
}
function OrderGetString(property) {
  if (property === ORDER_SYMBOL) return selectedOrder.symbol;
  if (property === ORDER_COMMENT) return selectedOrder.comment;
  return '';
}
function OrderGetInteger(property) {
  return property === ORDER_MAGIC ? selectedOrder.magic : 0;
}
function HistoryDealSelect() { return true; }
function HistoryDealGetInteger(_ticket, property) {
  if (property === DEAL_MAGIC) return activeDeal.magic;
  if (property === DEAL_ENTRY) return activeDeal.entry;
  if (property === DEAL_ORDER) return activeDeal.order;
  return 0;
}
function HistoryOrderSelect(ticket) { return ticket === activeDeal.order; }
function HistoryOrderGetString(_ticket, property) {
  return property === ORDER_COMMENT ? activeDeal.comment : '';
}
function SymbolInfoTick() { return tick; }
function GlobalVariableSet(key, value) { globals[key] = value; }
function TimeCurrent() { return currentTime; }
function TrailingDirectionKey() { return `${g_stateKey}.T`; }
function ThirdLevelResolvedKey() { return `${g_stateKey}.R`; }
function FixedCaseKey() { return `${g_stateKey}.C`; }
function FixedCaseDirectionKey() { return `${g_stateKey}.D`; }
function NormalizePrice(price) { return Number((Math.round(price / g_tickSize) * g_tickSize).toFixed(_Digits)); }
function MathFloor(value) { return Math.floor(value); }
function MathAbs(value) { return Math.abs(value); }
function MathMax(a, b) { return Math.max(a, b); }
function MathMin(a, b) { return Math.min(a, b); }
function DoubleToString(value, digits) { return Number(value).toFixed(digits); }
function StringFind(value, search) { return String(value).indexOf(search); }
function StringFormat(format, value) {
  return format === '|L%02d' ? `|L${String(value).padStart(2, '0')}` : format;
}
function Print(...args) { logs.push(args.join(' ')); }

eval(productionFunctions);

let passed = 0;
function test(name, body) {
  try {
    body();
    passed += 1;
    console.log(`PASS ${name}`);
  } catch (error) {
    error.message = `${name}: ${error.message}`;
    throw error;
  }
}
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function sendLevel3Fill(direction, comment = `SG9|${direction > 0 ? 'B' : 'S'}|L03`) {
  activeDeal.comment = comment;
  const trans = {
    type: TRADE_TRANSACTION_DEAL_ADD,
    symbol: _Symbol,
    deal: 77,
    deal_type: direction > 0 ? DEAL_TYPE_BUY : DEAL_TYPE_SELL,
  };
  OnTradeTransaction(trans, {}, {});
}
function evaluateSettledLevel3(direction) {
  EvaluateThirdLevelCase(direction);
}
function addFilledPosition(direction, level) {
  const ticket = Math.max(0, ...positions.map((position) => position.ticket)) + 1;
  positions.push({
    ticket,
    symbol: _Symbol,
    magic: InpMagicNumber,
    type: direction > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL,
    comment: `SG9|${direction > 0 ? 'B' : 'S'}|L${String(level).padStart(2, '0')}`,
    sl: g_anchorPrice,
    tp: g_anchorPrice + direction * 20.0,
  });
}

test('3-0 Buy cancels all EA pending and installs the initial SL on its three positions', () => {
  reset({ direction: 1, same: 3, opposite: 0 });
  sendLevel3Fill(1);
  assert(g_trailingDirection === 0 && !g_level3Evaluated, 'the transaction callback evaluated positions before they settled');
  evaluateSettledLevel3(1);
  assert(g_trailingDirection === 1, 'Buy trailing was not activated');
  assert(g_level3Evaluated && globals[`${g_stateKey}.R`] === 1, '3-0 evaluation was not persisted');
  assert(orders.length === 1 && orders[0].ticket === 9999, 'not all EA pending orders were canceled or an unrelated order was removed');
  assert(positions.length === 3 && positions.every((position) => position.sl === 4003), 'initial Buy SL was not level 1 + $1');
  assert(positions.every((position) => position.tp === 4020), 'the original Buy TP changed');
});

test('3-0 Buy advances SL by $1 at each $1 favorable step and never loosens it', () => {
  reset({ direction: 1, same: 3, opposite: 0 });
  sendLevel3Fill(1);
  evaluateSettledLevel3(1);
  tick = { bid: 4007.0, ask: 4007.2 };
  ManageTrailingStops(1);
  assert(positions.every((position) => position.sl === 4004), 'L3 + $1 did not move SL to L2');
  tick = { bid: 4008.0, ask: 4008.2 };
  ManageTrailingStops(1);
  assert(positions.every((position) => position.sl === 4005), 'L4 did not move SL to L2 + $1');
  tick = { bid: 4007.4, ask: 4007.6 };
  ManageTrailingStops(1);
  assert(positions.every((position) => position.sl === 4005), 'a retrace loosened the Buy SL');
  tick = { bid: 4004.9, ask: 4005.1 };
  ManageTrailingStops(1);
  assert(positions.length === 0, 'positions were not closed after price crossed the active Buy SL');
});

test('3-0 Sell mirrors the initial SL and trailing milestones', () => {
  reset({ direction: -1, same: 3, opposite: 0 });
  sendLevel3Fill(-1);
  evaluateSettledLevel3(-1);
  assert(g_trailingDirection === -1, 'Sell trailing was not activated');
  assert(orders.length === 1 && orders[0].ticket === 9999, 'Sell 3-0 did not cancel all EA pending');
  assert(positions.length === 3 && positions.every((position) => position.sl === 3997), 'initial Sell SL was not mirrored');
  assert(positions.every((position) => position.tp === 3980), 'the original Sell TP changed');
  tick = { bid: 3992.8, ask: 3993.0 };
  ManageTrailingStops(-1);
  assert(positions.every((position) => position.sl === 3996), 'L3 - $1 did not move Sell SL to L2');
  tick = { bid: 3991.8, ask: 3992.0 };
  ManageTrailingStops(-1);
  assert(positions.every((position) => position.sl === 3995), 'L4 did not move Sell SL to L2 - $1');
});

for (const scenario of [
  { name: '4-0', same: 4, opposite: 0 },
  { name: '2-0', same: 2, opposite: 0 },
]) {
  test(`${scenario.name} leaves the special rule inactive`, () => {
    reset(scenario);
    sendLevel3Fill(1);
    evaluateSettledLevel3(1);
    assert(g_trailingDirection === 0, 'trailing activated outside exact 3-0');
    assert(g_level3Evaluated, 'the unmatched case was not marked as evaluated');
    assert(orders.length === 19, 'pending orders changed outside exact 3-0');
    assert(positions.every((position) => position.sl === 4000), 'stops changed outside exact 3-0');
  });
}

for (const scenario of [
  { name: '3-1', caseId: 1, same: 3, opposite: 1, targetLevel: 4, stopLevel: 3 },
  { name: '3-2', caseId: 2, same: 3, opposite: 2, targetLevel: 5, stopLevel: 4 },
  { name: '3-3', caseId: 3, same: 3, opposite: 3, targetLevel: 7, stopLevel: 6 },
  { name: '5-4', caseId: 4, same: 5, opposite: 4, targetLevel: 9, stopLevel: 8 },
]) {
  for (const direction of [1, -1]) {
    test(`${scenario.name} ${direction > 0 ? 'Buy' : 'Sell'} sets main-side TP, then fixed SL and deletes pending at target fill`, () => {
      reset({ direction, same: scenario.same, opposite: scenario.opposite });
      ManageGridExitRules();

      assert(g_fixedCaseId === scenario.caseId, `${scenario.name} was not selected`);
      assert(g_fixedCaseDirection === direction, `${scenario.name} selected the wrong main direction`);
      const targetPrice = 4000 + direction * (scenario.targetLevel * InpGridStepPrice + 1.0);
      const stopPrice = 4000 + direction * (scenario.stopLevel * InpGridStepPrice + 1.0);
      const mainPositions = positions.filter((position) => position.type === (direction > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL));
      const oppositePositions = positions.filter((position) => position.type === (direction > 0 ? POSITION_TYPE_SELL : POSITION_TYPE_BUY));
      assert(mainPositions.every((position) => position.tp === targetPrice), `${scenario.name} main-side TP was not set`);
      assert(oppositePositions.every((position) => position.tp === 4000 - direction * 20.0), `${scenario.name} changed the opposite-side TP`);
      assert(mainPositions.every((position) => position.sl === 4000), `${scenario.name} set SL before the target level filled`);
      assert(orders.length === 19, `${scenario.name} deleted pending before the target level filled`);

      const targetEntry = 4000 + direction * scenario.targetLevel * InpGridStepPrice;
      tick = direction > 0
        ? { bid: targetEntry, ask: targetEntry + 0.2 }
        : { bid: targetEntry - 0.2, ask: targetEntry };
      addFilledPosition(direction, scenario.targetLevel);
      ManageConfiguredCase();

      const allMainPositions = positions.filter((position) => position.type === (direction > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL));
      assert(orders.length === 1 && orders[0].ticket === 9999, `${scenario.name} did not delete all EA pending orders`);
      assert(allMainPositions.every((position) => position.sl === stopPrice), `${scenario.name} did not set the fixed SL at the specified level`);
      assert(allMainPositions.every((position) => position.tp === targetPrice), `${scenario.name} did not retain the target TP`);
      assert(oppositePositions.every((position) => position.sl === 4000 && position.tp === 4000 - direction * 20.0), `${scenario.name} changed opposite-side exits`);

      tick = direction > 0
        ? { bid: targetPrice - 0.2, ask: targetPrice }
        : { bid: targetPrice, ask: targetPrice + 0.2 };
      ManageConfiguredCase();
      assert(allMainPositions.every((position) => position.sl === stopPrice), `${scenario.name} moved its fixed SL afterward`);
      assert(positions.length === scenario.same + scenario.opposite + 1, `${scenario.name} unexpectedly closed positions`);
    });
  }
}

test('a level-4 fill does not invoke the level-3 rule, even in 3-0 counts', () => {
  reset({ direction: 1, same: 3, opposite: 0 });
  sendLevel3Fill(1, 'SG9|B|L04');
  assert(!g_level3Evaluated && g_trailingDirection === 0, 'a non-L03 order invoked the special rule');
  assert(orders.length === 19, 'a non-L03 fill canceled pending orders');
});

test('a crossed unprotected case SL retries basket closure no faster than every 30 seconds', () => {
  reset({ direction: 1, same: 3, opposite: 1 });
  ManageGridExitRules();
  addFilledPosition(1, 4);
  tick = { bid: 4006.9, ask: 4007.1 };
  allowPositionClose = false;
  ManageConfiguredCase();
  const attemptsAfterFirstCall = positionCloseAttempts;
  assert(attemptsAfterFirstCall > 0, 'the unprotected crossed-SL basket was not closed');
  assert(g_fixedCaseCloseRetryAfter === 1030, 'the first retry delay was not scheduled');
  currentTime = 1010;
  ManageConfiguredCase();
  assert(positionCloseAttempts === attemptsAfterFirstCall, 'the close retry was not throttled');
  currentTime = 1030;
  ManageConfiguredCase();
  assert(positionCloseAttempts > attemptsAfterFirstCall, 'the close retry did not resume after the delay');
});

test('a price gap through case TP closes the main basket and retires pending orders', () => {
  reset({ direction: 1, same: 3, opposite: 1 });
  ManageGridExitRules();
  addFilledPosition(1, 4);
  tick = { bid: 4010.0, ask: 4010.2 };
  ManageConfiguredCase();
  assert(orders.length === 1 && orders[0].ticket === 9999, 'TP-gap handling left EA pending orders active');
  assert(positions.length === 1 && positions[0].type === POSITION_TYPE_SELL, 'TP-gap handling did not close only the main-side basket');
  assert(positionCloseAttempts === 4, 'TP-gap handling did not close every main-side position');
});

test('a crossed TP already attached to every main position is left to the server-side exits', () => {
  reset({ direction: 1, same: 3, opposite: 1 });
  ManageGridExitRules();
  addFilledPosition(1, 4);
  tick = { bid: 4008.0, ask: 4008.2 };
  ManageConfiguredCase();
  tick = { bid: 4009.2, ask: 4009.4 };
  ManageConfiguredCase();
  assert(positionCloseAttempts === 0, 'the EA sent a redundant market-close request after all positions had the TP');
  assert(orders.length === 1 && orders[0].ticket === 9999, 'crossed TP handling did not retire EA pending orders');
});

test('L03 position counting is deferred until all three positions are visible', () => {
  reset({ direction: 1, same: 2, opposite: 0 });
  sendLevel3Fill(1);
  assert(g_trailingDirection === 0 && !g_level3Evaluated, 'an incomplete transaction snapshot was evaluated');
  positions.push({ ticket: 3, symbol: _Symbol, magic: InpMagicNumber, type: POSITION_TYPE_BUY,
    comment: 'SG9|B|L03', sl: g_anchorPrice, tp: g_anchorPrice + 20.0 });
  evaluateSettledLevel3(1);
  assert(g_trailingDirection === 1, 'the settled 3-0 positions did not activate trailing');
  assert(orders.length === 1 && orders[0].ticket === 9999, 'the settled 3-0 case did not cancel all EA pending orders');
});

console.log(`PASS: ${passed} deterministic exit behavior scenarios`);
