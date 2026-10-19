from pathlib import Path
import subprocess, json, hashlib, tempfile, os, shutil
root=Path(__file__).resolve().parents[1]
scratch=tempfile.TemporaryDirectory(prefix='zonemusic-tests-')
out=Path(scratch.name)
s=(root/'zonemusic.lua').read_text(encoding='utf-8')
setup=r'''
package.path=MODULE_PATH..package.path;
local clock=100; os.clock=function()return clock;end;
local zone=165; local covered=true; local hp=100;
local player={Status=0,StatusServer=0}; local mobs={};
local assets={['day_165.wav']=true};
local party={GetMemberZone=function(self,i)return i==0 and zone or 0;end,
 GetMemberHPPercent=function()return hp;end, GetMemberServerId=function()return 123;end};
AshitaCore={GetMemoryManager=function()return {GetParty=function()return party;end};end};
function GetPlayerEntity()return player;end;
function GetEntity(i)return mobs[i];end;
function file_exists(name)return assets[name]==true;end;
function zone_is_covered_expansion()return covered;end;
function get_canonical_zone(z)return z;end;
function get_city_group()return nil;end;
function get_vana_hour()return 12;end;
function is_zone_disabled()return false;end;
local jukebox={}; local saved_bgm_ids={day=1,night=2,solo=121,party=121};
local music_config={enabled=true,enable_battle=true,battle_delay=0,enable_zone=true,battle_mode=1};
local battle_start_timer=0; local battle_end_timer=0; local previous_status=0;
local current_track=''; local current_random_track=''; local nm_scan_result=nil;
local unique_nm_scan_result=nil; local last_unique_nm_track=''; local in_crisis_mode=false;
local unique_nm_list={}; local unique_nm_scan_time=0; local nm_scan_interval=1; local unique_nm_scan_timer=0;
local unique_nm_last_scan=0; local last_unique_nm_scan=0;
local is_dead=false; local current_state=''; local callbacks={};
ashita={events={register=function(kind,name,fn)callbacks[name]=fn;end}};
'''
adapter=s[s.index('-- Keep boss state on the existing helper table'):s.index('-- 6. Playback Engine')]
cover=s[s.index('function jukebox.shadow_covers'):s.index('function jukebox.is_covered_engine_track')]
handler=s[s.index("ashita.events.register('text_in', 'zonemusic_shadow_text'"):s.index("ashita.events.register('text_in', 'zonemusic_fishing_text'")]
tests=r'''
local function tick()clock=clock+1; return get_desired_track();end;
local function msg(m)callbacks.zonemusic_shadow_text({message=m});end;
assert(tick()=='day_165.wav','idle theme changed');
assets['shadow_battle.wav']=true; assets['shadow_battle_2.wav']=true;
assert(tick()=='day_165.wav','boss music played before engagement');
player.Status=1; mobs[10]={Name='Shadow Lord',ServerId=1000,Status=1,HPPercent=100};
music_config.battle_delay=8;
assert(tick()=='shadow_battle.wav','engage delay inserted idle music');
assert(unique_nm_scan_result=='shadow_battle.wav' and last_unique_nm_track=='shadow_battle.wav');
assert(jukebox.shadow_covers(121,2) and jukebox.shadow_covers(121,3));
assert(not jukebox.shadow_covers(121,0) and not jukebox.shadow_covers(77,2));
player.Status=0; mobs[10].Status=0; tick(); player.Status=1; mobs[10].Status=1;
assert(tick()=='shadow_battle.wav' and jukebox.shadow.phase==1,'re-engage advanced phase');
msg('Moonrise defeats the Shadow Lord.');
assert(tick()=='shadow_battle.wav','stale phase-one entity advanced phase');
mobs={}; player.Status=0;
assert(tick()=='shadow_battle.wav','phase gap selected generic music');
mobs[11]={Name='Shadow Lord',ServerId=1001,Status=1,HPPercent=100};player.Status=1;
assert(tick()=='shadow_battle_2.wav','replacement boss did not select phase two');
assert(unique_nm_scan_result=='shadow_battle_2.wav');
msg('The Shadow Lord uses Implosion.'); assert(tick()=='shadow_battle_2.wav');
assets['shadow_battle_2.wav']=nil; assert(tick()=='shadow_battle.wav','missing phase two fallback');
player.StatusServer=4;assert(jukebox.shadow_track()==nil and not jukebox.shadow_covers(121,2),'cutscene stolen');
player.StatusServer=0;music_config.enable_battle=false;assert(jukebox.shadow_track()==nil);music_config.enable_battle=true;
covered=false;assert(not jukebox.shadow_covers(121,2));covered=true;
hp=0;player.Status=2;assert(tick()=='' and not jukebox.shadow_covers(121,2),'death music stolen');
hp=100;player.Status=1;assets['shadow_battle_2.wav']=true;
msg('Battlefield clear time: 1 minute, 58 seconds!');
assert(tick()=='day_165.wav','stale engaged state restarted battle after clear');
zone=166;assert(jukebox.shadow_track()==nil and jukebox.shadow.phase==1 and not jukebox.shadow.finished);
zone=165;jukebox.shadow:reset();jukebox.shadow_poll=nil;
msg('The Shadow Lord uses Implosion.');assert(tick()=='shadow_battle_2.wav','mid-phase reload fallback');
-- Same entity can be reused once a disengaged gap confirms phase separation.
jukebox.shadow:reset();jukebox.shadow_poll=nil;assert(tick()=='shadow_battle.wav');
msg('Moonrise defeats the Shadow Lord.');mobs[11].Status=0;tick();mobs[11].Status=1;
assert(tick()=='shadow_battle_2.wav');
-- Missing both assets leaves the existing generic battle selector available.
assets['shadow_battle.wav']=nil;assets['shadow_battle_2.wav']=nil;
assert(jukebox.shadow_track()==nil and not jukebox.shadow_covers(121,2));
music_config.battle_delay=0;assets['battle_165_solo.wav']=true;
assert(tick()=='battle_165_solo.wav','legacy battle selection broken');
assert(('shadow_battle.wav'):match('_battle%.wav$'));
print('PASS: actual selector, native coverage, phase changes, gaps, replay guard, missing audio, settings, death, cutscene and zone isolation');
'''
handoff_tests=r'''
local begins=0; local injections={};
local handoff={active=false};
local engine_signal={last_poll=0,path='mock-signal',last_counter=1,last_resilence=0,resilence_interval=2};
local ENGINE_SIGNAL_POLL=.15; local ENGINE_SILENCE_ID=0;
local zone_is_playing=true; local zone_is_paused=false;local battle_is_playing=true;
local DEBUG_CUTSCENE=false;
local function begin_handoff()begins=begins+1;handoff.active=true;end;
local resumes=0;
local function end_handoff(resume)assert(resume==false);resumes=resumes+1;handoff.active=false;end;
local function inject_engine_music(slot,id)injections[slot]=id;end;
local function is_cinematic_zone()return true;end;
local real_open=io.open;local signal='2 121';
io.open=function()return {read=function()return signal;end,close=function()end};end;
struct={unpack=function(kind,data,pos)return pos==5 and data.slot or data.song;end};
'''
intro_helpers=s[s.index('jukebox.shadow_intro = {};'):s.index('function jukebox.shadow_covers')]
native=s[s.index('-- The native battle stream can arrive'):s.index('function jukebox.is_covered_engine_track')]
covered=s[s.index('function jukebox.is_covered_engine_track'):s.index('-- End of an engine handoff:')]
poll=s[s.index('local function poll_engine_signal()'):s.index('local function get_idle_replay_delay()')]
packet=s[s.index('    if (e.id == 0x05F) then\n        local mtype'):s.index('    -- 0x052 = Menu Event Update / Release')]
recovery=s[s.index('        -- A battle stream can open just before'):s.index('        if (handoff.active) then\n            if (in_status4) then')]
handoff_checks=r'''
assets['shadow_battle.wav']=true;assets['shadow_battle_2.wav']=true;
jukebox.shadow:reset();jukebox.shadow_poll=nil;clock=clock+1;
poll_engine_signal();assert(begins==0,'covered helper signal triggered handoff');
assert(injections[2]==0 and injections[3]==0,'native battle slots not silenced');
local e={id=0x05F,data={slot=2,song=121}};packet_music(e);
assert(e.blocked and begins==0,'battle packet triggered handoff');
e={id=0x05F,data={slot=3,song=121}};packet_music(e);assert(e.blocked);
player.StatusServer=4;e={id=0x05F,data={slot=2,song=121}};packet_music(e);
assert(not e.blocked and begins==1,'event battle music blocked');
player.StatusServer=0;handoff.active=false;e={id=0x05F,data={slot=2,song=77}};packet_music(e);
assert(not e.blocked and begins==2,'uncovered event music blocked');
handoff.active=false;clock=clock+1;signal='3 77';poll_engine_signal();
assert(begins==3,'uncovered helper music did not hand off');
handoff.shadow_song=121;handoff.saw_event=false;recover(false);
assert(not handoff.active and resumes==1,'pre-engagement battle handoff lingered');
handoff.active=true;handoff.shadow_song=77;recover(false);assert(handoff.active and resumes==1);
handoff.shadow_song=121;recover(true);assert(handoff.active and resumes==1);
handoff.saw_event=true;recover(false);assert(handoff.active and resumes==1);
io.open=real_open;
print('PASS: actual native music packet and helper-signal paths block covered battle restarts and preserve genuine event music');
'''

handoff_checks+=r"""
-- Replay the observed settings and the post-cutscene/pre-engagement gap.
saved_bgm_ids={day=155,night=155,solo=119,party=119};
player.Status=0;player.StatusServer=0;mobs={};
jukebox.shadow:reset();jukebox.shadow_poll=nil;handoff.active=false;
assets['shadow_battle.wav']=true;assets['shadow_battle_2.wav']=true;
assert(jukebox.shadow_track()==nil);
assert(jukebox.shadow_native_covers(119,2) and jukebox.shadow_native_covers(155,0));
assert(not jukebox.shadow_native_covers(119,0) and not jukebox.shadow_native_covers(155,2));
local previous_begins=begins;
io.open=function()return {read=function()return signal;end,close=function()end};end;
for i=1,5 do
 clock=clock+1;signal=(10+i)..' 119';poll_engine_signal();
 assert(begins==previous_begins and not handoff.active,'pre-engagement native restart loop');
end
io.open=real_open;
e={id=0x05F,data={slot=2,song=119}};packet_music(e);assert(e.blocked);
-- Teleport/menu exit gets its suppression before the half-second DJ tick.
player.StatusServer=4;assert(not jukebox.shadow_event_exit());
injections={};player.StatusServer=0;
assert(jukebox.shadow_event_exit(),'event exit was not detected');
assert(injections[0]==0 and injections[1]==0 and injections[2]==0 and injections[3]==0);
injections={};assert(not jukebox.shadow_event_exit() and next(injections)==nil,'exit repeated each frame');
-- Preserve genuine events, disabled/missing coverage and other zones.
player.StatusServer=4;assert(not jukebox.shadow_native_covers(119,2));
e={id=0x05F,data={slot=2,song=119}};packet_music(e);assert(not e.blocked);
player.StatusServer=0;handoff.active=false;
music_config.enabled=false;assert(not jukebox.shadow_native_covers(119,2));music_config.enabled=true;
music_config.enable_battle=false;assert(not jukebox.shadow_native_covers(119,2));music_config.enable_battle=true;
assets['shadow_battle.wav']=nil;assets['shadow_battle_2.wav']=nil;
assert(not jukebox.shadow_native_covers(119,2));assets['shadow_battle.wav']=true;
zone=166;assert(not jukebox.shadow_native_covers(119,2));zone=165;
player.StatusServer=4;handoff.active=true;jukebox.shadow_event_exit();player.StatusServer=0;
assert(not jukebox.shadow_event_exit(),'active event grace bypassed');handoff.active=false;
-- Actual handoff end must clear all covered slots, not only day/night.
local day_resumes=0;local engine_resumes=0;
local function engine_silence()engine_resumes=engine_resumes+1;end;
local function resume_zone_music_fast()day_resumes=day_resumes+1;end;
jukebox.moghouse_owns_audio=function()return false;end;
zone_is_paused=true;injections={};
"""
actual_end=s[s.index('local function end_handoff(resume_wav)'):s.index('-- Begin an engine handoff:')]
handoff_checks+=actual_end+r"""
handoff.active=true;end_handoff(true);
assert(not handoff.active and engine_resumes==1 and day_resumes==1);
assert(injections[2]==0 and injections[3]==0,'battle slots left native at event end');
print('PASS: captured 119/155 sequence, pre-engagement ownership, frame event exit, all-four-slot event cleanup and coverage exclusions');
"""


handoff_checks+=r"""
-- Reproduce the latest capture: reload in zone with every resident id nil.
music_config.zone_bgm={['165']={day=155,night=155,solo=119,party=119,mount=212}};
saved_bgm_ids={};jukebox.shadow_reset_intro();jukebox.shadow:reset();jukebox.shadow_poll=nil;
player.Status=0;player.StatusServer=4;mobs={};handoff.active=false;
local initial_begins=begins;
io.open=function()return {read=function()return signal;end,close=function()end};end;
clock=clock+1;signal='100 119';poll_engine_signal();
assert(begins==initial_begins+1 and handoff.active,'first intro was suppressed');
assert(saved_bgm_ids.day==155 and saved_bgm_ids.solo==119,'reload ids not recovered');
assert(jukebox.shadow_intro.song==119 and not jukebox.shadow_intro.locked);
player.StatusServer=0;handoff.saw_event=true;injections={};end_handoff(true);
assert(jukebox.shadow_intro.locked and jukebox.shadow_intro.song==119,'intro not locked after end');
assert(injections[2]==0 and injections[3]==0);
for i=1,4 do
 clock=clock+1;signal=(100+i)..' 119';poll_engine_signal();
 assert(begins==initial_begins+1 and not handoff.active,'repeat intro took ownership');
end
player.Status=1;mobs[10]={Name='Shadow Lord',ServerId=1000,Status=1,HPPercent=100};
assert(tick()=='shadow_battle.wav','phase-one track was not selected');
clock=clock+1;signal='105 119';poll_engine_signal();
assert(not handoff.active and begins==initial_begins+1,'intro interrupted battle');
-- An actual subsequent scene keeps native ownership even for the same song.
player.StatusServer=4;clock=clock+1;signal='106 119';poll_engine_signal();
assert(handoff.active and begins==initial_begins+2,'real later scene was muted');
player.StatusServer=0;handoff.active=false;
-- Fresh packet fields always beat the settings fallback.
saved_bgm_ids={day=0,night=99,solo=77,party=88};jukebox.shadow_recover_bgm();
assert(saved_bgm_ids.day==0 and saved_bgm_ids.night==99 and saved_bgm_ids.solo==77 and saved_bgm_ids.party==88);
-- Next visit resets the one-visit lock; a new intro can play normally.
jukebox.shadow_reset_intro();saved_bgm_ids={};player.StatusServer=4;
clock=clock+1;signal='107 119';poll_engine_signal();
assert(handoff.active and not jukebox.shadow_intro.locked and jukebox.shadow_intro.song==119);
io.open=real_open;
print('PASS: nil music ids on reload, first intro allowed, repeat lock, engage continuity, real later cutscene allowed, fresh ids preserved and next-visit reset');
"""

setup=setup.replace('MODULE_PATH',json.dumps(root.as_posix()+'/?.lua;'))
p=out/'test-shadow-music.lua';p.write_text(setup+intro_helpers+adapter+cover+handler+tests+handoff_tests+native+covered+poll+'\nlocal function packet_music(e)\n'+packet+'end\nlocal function recover(in_status4)\n'+recovery+'end\n'+handoff_checks,encoding='utf-8')
r=subprocess.run([os.environ.get('LUA') or shutil.which('lua') or r'C:\Program Files\Lua\lua.exe',str(p)],capture_output=True,text=True)
print(r.stdout,r.stderr);assert r.returncode==0
# Check the packet and helper paths use the same coverage decision.
assert 'or jukebox.shadow_covers(song, mtype)' in s
assert 'or jukebox.shadow_native_covers(music_id) or not in_event' in s
assert 'and jukebox.shadow_track() == nil) then' in s
assert s.count('jukebox.shadow:reset();')==4
result={'tests':r.stdout.strip(),'engine_compatibility':'Automated mock regression only; live confirmation is tracked separately in MAINTENANCE.md',
 'audio_modified':False,'day_track_modified':False}
(out/'verification.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
