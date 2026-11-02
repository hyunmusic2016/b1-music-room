/**
 * 현실용음악학원 B1 음악 연습실 예약 — 재원생 명부 보내기 (구글 시트 Apps Script)
 *
 * 하는 일: "수강생대장" 탭에서 학생마다 등록번호 · 학생 이름 · 전화번호 뒤 4자리만 골라 예약 서버로 보냅니다.
 *   - 이름/보호자 칸에 "학생/보호자"처럼 적혀 있으면 "/" 앞(학생 이름)만 씁니다.
 *   - 비밀번호(뒤 4자리)는 원생 전화번호, 원생 번호가 비어 있으면 보호자 전화번호에서 가져옵니다.
 *   - 퇴원 연월일이 적힌 줄은 보내지 않습니다.
 *   - 전체 전화번호, 보호자 이름, 파트·강사·요일 등 다른 칸은 보내지 않습니다.
 *
 * 연동 열쇠는 이 코드에 적지 않습니다. 시트 메뉴 [예약 명부 → 연동 열쇠 넣기]로 넣으면
 * 이 스크립트의 설정(Script Properties)에만 저장됩니다.
 */

// ▼ 시트 아래쪽 탭 이름이 다르면 이 줄만 고치십시오.
const SHEET_NAME = '수강생대장';
// ▼ 칸 이름(등록번호, 이름/보호자 …)이 있는 줄 번호
const HEADER_ROW = 3;

// 예약 서버 주소와 공개용 키(화면에도 들어 있는 공개 값입니다. 비밀 키가 아닙니다.)
const SUPABASE_URL = 'https://ibcvbnpqmlqmdwxkepbl.supabase.co';
const SUPABASE_KEY = 'sb_publishable_EuDlhpMAm69J4qB0pMFVYA_bh5RWzo2';

// 칸 이름(3번째 줄 글자)으로 칸을 찾습니다. 칸 순서가 바뀌어도 됩니다.
const COL = {
  no: '등록번호',
  name: '이름/보호자',
  phone: '원생 전화번호',
  parent: '보호자 전화번호',
  left: '퇴원 연월일'
};

/** 시트를 열 때 위쪽에 [예약 명부] 메뉴를 만듭니다. */
function onOpen() {
  SpreadsheetApp.getUi().createMenu('예약 명부')
    .addItem('지금 반영', 'syncNow')
    .addItem('강제로 반영 (학생이 한꺼번에 많이 빠졌을 때)', 'syncForce')
    .addSeparator()
    .addItem('연동 열쇠 넣기', 'setToken')
    .addItem('1시간마다 자동 반영 켜기', 'installTrigger')
    .addToUi();
}

/** 관리자 화면에서 만든 연동 열쇠를 저장합니다. */
function setToken() {
  const ui = SpreadsheetApp.getUi();
  const r = ui.prompt('연동 열쇠 넣기', '예약 관리자 화면(설정 > 재원생 명부 연동)에서 만든 열쇠를 붙여 넣으십시오.', ui.ButtonSet.OK_CANCEL);
  if (r.getSelectedButton() !== ui.Button.OK) return;
  const tk = r.getResponseText().trim();
  if (!/^[0-9a-f]{48}$/.test(tk)) { ui.alert('열쇠 모양이 맞지 않습니다. 관리자 화면에서 복사한 48글자를 그대로 붙여 넣으십시오.'); return; }
  PropertiesService.getScriptProperties().setProperty('ROSTER_TOKEN', tk);
  ui.alert('연동 열쇠를 저장했습니다. 이제 [예약 명부 → 지금 반영]을 눌러 보십시오.');
}

/** 1시간마다 자동으로 보내도록 설정합니다(같은 설정이 이미 있으면 지우고 새로 만듭니다). */
function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => { if (t.getHandlerFunction() === 'syncHourly') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('syncHourly').timeBased().everyHours(1).create();
  SpreadsheetApp.getUi().alert('1시간마다 자동으로 명부를 보냅니다.');
}

/** 시트에서 보낼 줄을 만듭니다. */
function readRows_() {
  const sh = SpreadsheetApp.getActive().getSheetByName(SHEET_NAME);
  if (!sh) throw new Error('"' + SHEET_NAME + '" 탭을 찾을 수 없습니다. 코드 맨 위 SHEET_NAME을 탭 이름과 같게 고치십시오.');
  const v = sh.getDataRange().getDisplayValues();
  const head = (v[HEADER_ROW - 1] || []).map(s => String(s).replace(/\s+/g, ' ').trim());
  const idx = {};
  Object.keys(COL).forEach(k => { idx[k] = head.indexOf(COL[k]); });
  ['no', 'name', 'phone'].forEach(k => {
    if (idx[k] < 0) throw new Error(HEADER_ROW + '번째 줄에서 "' + COL[k] + '" 칸을 찾을 수 없습니다.');
  });
  const rows = [], noPhone = [];
  for (let i = HEADER_ROW; i < v.length; i++) {
    const r = v[i];
    const no = String(r[idx.no] || '').trim();
    if (!no) continue;                                            // 빈 줄
    if (idx.left >= 0 && String(r[idx.left] || '').trim()) continue; // 퇴원한 학생
    const name = String(r[idx.name] || '').split('/')[0].replace(/\s+/g, '');
    let digits = String(r[idx.phone] || '').replace(/\D/g, '');
    if (digits.length < 4 && idx.parent >= 0) digits = String(r[idx.parent] || '').replace(/\D/g, '');
    if (digits.length < 4) { noPhone.push(no); continue; }
    rows.push({ no: no, name: name, pw4: digits.slice(-4) });
  }
  return { rows: rows, noPhone: noPhone };
}

/** 서버로 보내고 결과를 돌려받습니다. */
function send_(force) {
  const tk = PropertiesService.getScriptProperties().getProperty('ROSTER_TOKEN');
  if (!tk) throw new Error('연동 열쇠가 없습니다. [예약 명부 → 연동 열쇠 넣기]를 먼저 하십시오.');
  const data = readRows_();
  const res = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/roster_sync', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: SUPABASE_KEY },
    payload: JSON.stringify({ p_token: tk, p_rows: data.rows, p_force: !!force }),
    muteHttpExceptions: true
  });
  let out;
  try { out = JSON.parse(res.getContentText()); } catch (e) { out = { ok: false, msg: '서버 응답을 읽지 못했습니다 (' + res.getResponseCode() + ').' }; }
  if (res.getResponseCode() >= 300 && out && out.message) out = { ok: false, msg: out.message };
  out.noPhone = data.noPhone;
  return out;
}

function resultText_(r) {
  if (!r.ok) return '반영하지 못했습니다.\n' + (r.msg || '');
  let t = '반영했습니다. 명부 ' + r.count + '명 (새로 ' + r.added + '명, 바뀜 ' + r.changed + '명, 빠짐 ' + r.removed + '명' + (r.linked ? ', 자동 연결 ' + r.linked + '명' : '') + ')';
  if (r.skipped && r.skipped.length) t += '\n이름 모양이 맞지 않아 건너뛴 등록번호: ' + r.skipped.join(', ');
  if (r.noPhone && r.noPhone.length) t += '\n전화번호가 없어 건너뛴 등록번호: ' + r.noPhone.join(', ');
  return t;
}

function syncNow() {
  try { SpreadsheetApp.getUi().alert(resultText_(send_(false))); }
  catch (e) { SpreadsheetApp.getUi().alert(e.message); }
}
function syncForce() {
  const ui = SpreadsheetApp.getUi();
  if (ui.alert('강제로 반영', '학생이 한꺼번에 많이 빠져도 그대로 반영합니다. 시트가 맞는지 확인하셨습니까?', ui.ButtonSet.YES_NO) !== ui.Button.YES) return;
  try { ui.alert(resultText_(send_(true))); } catch (e) { ui.alert(e.message); }
}
/** 1시간마다 자동 실행(창 없이 기록만 남김) */
function syncHourly() {
  try { console.log(resultText_(send_(false))); } catch (e) { console.error(e.message); }
}
