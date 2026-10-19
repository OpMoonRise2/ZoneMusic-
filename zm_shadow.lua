-- Encounter state is independent of voice playback and native music restarts.
local Shadow = {};
Shadow.__index = Shadow;

function Shadow.new()
    local self = setmetatable({}, Shadow);
    self:reset();
    return self;
end

function Shadow:reset()
    self.phase = 1;
    self.active = false;
    self.pending = false;
    self.finished = false;
    self.saw_gap = false;
    self.boss_id = nil;
    self.last_seen = 0;
end

function Shadow:observe(boss, now)
    if (self.finished) then return; end
    if (boss == nil) then
        if (self.pending) then self.saw_gap = true; end
        return;
    end
    if (self.pending and (self.saw_gap or boss ~= self.boss_id)) then
        self.phase = 2;
        self.pending = false;
    end
    self.active = true;
    self.boss_id = boss;
    self.last_seen = now;
end

function Shadow:message(msg, now)
    msg = msg:lower();
    if (msg:find('battlefield clear time:', 1, true) and (self.active or self.pending)) then
        self.finished = true;
        self.active = false;
    elseif (msg:find('defeats the shadow lord', 1, true)
        or msg:find('the shadow lord falls to the ground', 1, true)) then
        if (self.phase == 1) then
            self.pending = true;
            self.last_seen = now;
        else
            self.finished = true;
            self.active = false;
        end
    elseif (msg:find('the shadow lord uses implosion', 1, true)
        or msg:find('the shadow lord readies implosion', 1, true)) then
        self.phase = 2;
        self.pending = false;
        self.active = true;
        self.last_seen = now;
    end
end

function Shadow:track(now, exists)
    if (self.finished or not self.active or now - self.last_seen > 20) then return nil; end
    if (self.phase == 2 and exists('shadow_battle_2.wav')) then
        return 'shadow_battle_2.wav';
    end
    -- Keep phase one if phase two is not installed yet; never invent audio.
    if (exists('shadow_battle.wav')) then return 'shadow_battle.wav'; end
    return nil;
end

return Shadow;
