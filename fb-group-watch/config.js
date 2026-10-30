// FB Group Watch settings. No secrets here: the Facebook session lives in the
// persistent browser profile in profile/ (700, git-ignored).
const path = require('path');
module.exports = {
  agentName: 'FB Group Watch',
  brave: '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  groupURL: 'https://www.facebook.com/groups/dokanMultivendor',
  groupName: 'Dokan Multivendor',
  // GitPulse reads this file (pick it in GitPulse Settings ▸ Watch a Facebook group).
  outFile: path.join(__dirname, 'gitpulse-fb.json'),
  // Feed posts checked per sort order (newest 5). Small on purpose: fewer loads = lower ban risk.
  maxPosts: 5,
  // Your own comments never alert. Set to your name as Facebook shows it on
  // your comments ("Comment by NAME"). Empty = alert on every comment.
  selfName: '',
  // Events kept in the output file (oldest dropped).
  keepEvents: 200,
};
