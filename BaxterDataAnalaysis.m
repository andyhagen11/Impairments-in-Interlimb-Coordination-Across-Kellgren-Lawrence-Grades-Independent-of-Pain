%% Baxter Gait Analysis
% Computes spatiotemporal gait metrics (stride/step length, asymmetry,
% double support, swing time, cadence, gait speed), lower limb kinematics and their asymmetries, 
% and Phase Coordination Index (PCI; Plotnik et al. 2007, doi:10.1007/s00221-007-0955-7) from
% Visual3D-exported GaitEvents and Kinematics .mat structures.

clc
clear

RootDir = '/Volumes/orthofbfs/SPARC/Research_Drive/Hagen/Baxter_Veterans_OA/BiomechData';
ParentDir = fileparts(RootDir);

% Load the participant involved-side mapping once from the BaxterData root.
SideMapFile = fullfile(ParentDir, 'InvolvedSides.xlsx');
SubjectSideMap = containers.Map();
if isfile(SideMapFile)
    SideMap = readtable(SideMapFile, 'VariableNamingRule', 'preserve');
    varNames = SideMap.Properties.VariableNames;
    participantCol = find(cellfun(@(x) contains(x, 'Participant', 'IgnoreCase', true), varNames), 1);
    sideCol = find(cellfun(@(x) contains(x, 'Interest', 'IgnoreCase', true) || contains(x, 'Side', 'IgnoreCase', true), varNames), 1);

    if isempty(participantCol) || isempty(sideCol)
        error('Could not locate Participant/side columns in %s.', SideMapFile);
    end

    for i = 1:height(SideMap)
        subj = strtrim(char(SideMap{i, participantCol}));
        side = strtrim(char(SideMap{i, sideCol}));
        if strcmpi(side, 'Left')
            SubjectSideMap(subj) = 'Left';
        elseif strcmpi(side, 'Right')
            SubjectSideMap(subj) = 'Right';
        else
            warning('Unrecognized involved side "%s" for %s. Skipping mapping.', side, subj);
        end
    end
else
    warning('Could not find %s. Proceeding without participant-side mapping.', SideMapFile);
end

SubjDirs = dir(RootDir);
SubjDirs = SubjDirs([SubjDirs.isdir] & ~startsWith({SubjDirs.name}, '.'));

% Summary table and profiles across all participants
Group_SummaryTable = table();
GroupProfiles = struct();

for s = 1:numel(SubjDirs)
    Subj = SubjDirs(s).name;
    SubjPath = fullfile(RootDir, Subj);

    EventsFile = fullfile(SubjPath, [Subj '_GaitEvents.mat']);
    KinFile    = fullfile(SubjPath, [Subj '_Kinematics.mat']);

    if ~isfile(EventsFile) || ~isfile(KinFile)
        warning('Missing GaitEvents or Kinematics file for %s. Skipping.', Subj);
        continue
    end

    % Use only Walk_test trials (not Diagonal_walk, etc.)
    TrialPattern = 'Walk_test_\d+_Theia\.c3d$';

    % Fix for participants with trial names flipped
    if strcmp(Subj,"VA059") || strcmp(Subj,"VA060") 
        TrialPattern = 'Diagonal_walk_\d+_Theia\.c3d$';
    end

    if isKey(SubjectSideMap, Subj)
        involvedSide = SubjectSideMap(Subj);
        if strcmpi(involvedSide, 'Right')
            uninvolvedSideCode = 'L';
            involvedSideCode   = 'R';
        else
            uninvolvedSideCode = 'R';
            involvedSideCode   = 'L';
        end
    else
        warning('No involved-side mapping found for %s; using left/right labels for this subject.', Subj);
        uninvolvedSideCode = 'L';
        involvedSideCode   = 'R';
    end

    EventsData = load(EventsFile);
    KinData    = load(KinFile);

    % Identify matching trial indices independently in each structure
    EventsTrialIdx = find(~cellfun(@isempty, regexp(EventsData.FILE_NAME, TrialPattern, 'once')));
    KinTrialIdx    = find(~cellfun(@isempty, regexp(KinData.FILE_NAME, TrialPattern, 'once')));

    EventsNames = EventsData.FILE_NAME(EventsTrialIdx);
    KinNames    = KinData.FILE_NAME(KinTrialIdx);

    % Trial order may not align between the two structures, so match by
    % filename rather than assuming index correspondence
    if ~isequal(sort(EventsNames), sort(KinNames))
        warning('Trial name mismatch between Events and Kinematics for %s.', Subj);
    end

    fprintf('%s: %d walking trials identified\n', Subj, numel(EventsTrialIdx));

    % Skip participant if they have 0 valid walking trials
    if numel(EventsTrialIdx) == 0
        continue
    end

    FrameRate = EventsData.FRAME_RATE; % assumed identical to KinData.FRAME_RATE (100 Hz)
    if iscell(FrameRate), FrameRate = FrameRate{1}; end
    FrameRate = double(FrameRate);
    t2f = @(t) round(t * FrameRate) + 1; % event time (s) -> frame index (1-based)

    % Subject-level pooled arrays (accumulate across all Walk_test trials)
    Pool.RStrideLen   = [];
    Pool.LStrideLen   = [];
    Pool.RStrideTime  = [];
    Pool.LStrideTime  = [];
    Pool.RStepLen     = [];
    Pool.LStepLen     = [];
    Pool.RStepTime    = [];
    Pool.LStepTime    = [];
    Pool.RSwing       = [];
    Pool.LSwing       = [];
    Pool.RDblSupport  = [];
    Pool.LDblSupport  = [];
    Pool.RDblSupportPct = [];
    Pool.LDblSupportPct = [];
    Pool.RStancePct   = [];
    Pool.LStancePct   = [];
    Pool.Phi          = [];
    Pool.GaitSpeed    = [];       % per-frame CoM_Vel x-samples, direction-corrected
    Pool.TotalSteps   = 0;
    Pool.TotalTime_s  = 0;

    % Kinematics: per-cycle peaks/ROM (per side, pooled across trials)
    Pool.RHipPeakFlex = []; Pool.LHipPeakFlex = [];
    Pool.RHipPeakExt  = []; Pool.LHipPeakExt  = [];
    Pool.RHipPeakExtStance = []; Pool.LHipPeakExtStance = [];
    Pool.RHipPeakAdd  = []; Pool.LHipPeakAdd  = [];
    Pool.RHipPeakAbd  = []; Pool.LHipPeakAbd  = [];
    Pool.RHipPeakAddStance = []; Pool.LHipPeakAddStance = [];
    Pool.RHipPeakAbdStance = []; Pool.LHipPeakAbdStance = [];
    Pool.RHipSagROM   = []; Pool.LHipSagROM   = [];
    Pool.RHipFrontROM = []; Pool.LHipFrontROM = [];

    Pool.RKneePeakFlex = []; Pool.LKneePeakFlex = [];
    Pool.RKneePeakFlexStance = []; Pool.LKneePeakFlexStance = [];
    Pool.RKneePeakFlexSwing = []; Pool.LKneePeakFlexSwing = [];
    Pool.RKneePeakExt  = []; Pool.LKneePeakExt  = [];
    Pool.RKneePeakAdd  = []; Pool.LKneePeakAdd  = [];
    Pool.RKneePeakAbd  = []; Pool.LKneePeakAbd  = [];
    Pool.RKneePeakAddStance = []; Pool.LKneePeakAddStance = [];
    Pool.RKneePeakAbdStance = []; Pool.LKneePeakAbdStance = [];
    Pool.RKneeSagROM   = []; Pool.LKneeSagROM   = [];
    Pool.RKneeFrontROM = []; Pool.LKneeFrontROM = [];

    Pool.RAnklePeakDorsi   = []; Pool.LAnklePeakDorsi   = [];
    Pool.RAnklePeakPlantar = []; Pool.LAnklePeakPlantar = [];
    Pool.RAnklePeakInv     = []; Pool.LAnklePeakInv     = [];
    Pool.RAnklePeakEve     = []; Pool.LAnklePeakEve     = [];
    Pool.RAnkleSagROM      = []; Pool.LAnkleSagROM      = [];
    Pool.RAnkleFrontROM    = []; Pool.LAnkleFrontROM    = [];

    % Trunk: per-trial peaks (not per-side, not per-cycle), pooled across trials
    Pool.TrunkPeakFlex = [];
    Pool.TrunkPeakSway = [];

    % Time-normalized (0-100% gait cycle) waveforms, one column per cycle,
    % pooled across trials -- used for the average joint kinematic profile plot
    Pool.RHipSag = []; Pool.LHipSag = [];
    Pool.RHipFront = []; Pool.LHipFront = [];
    Pool.RKneeSag = []; Pool.LKneeSag = [];
    Pool.RKneeFront = []; Pool.LKneeFront = [];
    Pool.RAnkleSag = []; Pool.LAnkleSag = [];
    Pool.RAnkleFront = []; Pool.LAnkleFront = [];

    SubjCycleTable = table();
    TrialRowRanges = {};
    ProcessedEventIdx = [];
    TrialGaitSpeedVals = [];
    TrialCadenceVals = [];
    TrialPhiVals = [];
    TrialPhiCycleVals = {};

    %% Loop through matched walking trials
    for t = 1:numel(EventsTrialIdx)
        eIdx = EventsTrialIdx(t);
        TrialName = EventsData.FILE_NAME{eIdx};

        % Find corresponding trial in Kinematics structure by filename
        kIdx = find(strcmp(KinData.FILE_NAME, TrialName), 1);
        if isempty(kIdx)
            warning('No matching Kinematics trial for %s (%s). Skipping trial.', Subj, TrialName);
            continue
        end

        TrialTok = regexp(TrialName, 'Walk_test_(\d+)_Theia', 'tokens', 'once');
        if ~isempty(TrialTok)
            TrialNum = str2double(TrialTok{1});
        else
            TrialNum = t;
        end

        LFS = EventsData.LHS{eIdx,1}; LFS = LFS(:);
        RFS = EventsData.RHS{eIdx,1}; RFS = RFS(:);
        LTO = EventsData.LTO{eIdx,1}; LTO = LTO(:);
        RTO = EventsData.RTO{eIdx,1}; RTO = RTO(:);

        % Skip trials without enough heel strikes to define gait cycles
        if numel(RFS) < 2 || numel(LFS) < 2
            warning('%s: Skipping trial %s (RHS = %d, LHS = %d).', ...
                Subj, TrialName, numel(RFS), numel(LFS));
            continue
        end

        ProcessedEventIdx(end+1) = eIdx;

        RHeel  = KinData.R_Heel_Pos{kIdx,1}; % frames x 3 (x,y,z), mm
        LHeel  = KinData.L_Heel_Pos{kIdx,1};
        CoMVel = KinData.CoM_Vel{kIdx,1};

        % Walking direction correction: +1 if walking in +x, -1 if -x
        dirSign = sign(median(CoMVel(:,1), 'omitnan'));

        %% Stride length and stride time (per side): AP displacement and elapsed time between consecutive same-side heel strikes.
        RStrideLen = [dirSign * diff(RHeel(t2f(RFS),1)); NaN];
        LStrideLen = [dirSign * diff(LHeel(t2f(LFS),1)); NaN];
        RStrideTime = [diff(RFS(:)); NaN];
        LStrideTime = [diff(LFS(:)); NaN];

        %% Step length (per side): AP distance between heels at the instant of each heel strike
        RStepLen = dirSign * (RHeel(t2f(RFS),1) - LHeel(t2f(RFS),1));
        LStepLen = dirSign * (LHeel(t2f(LFS),1) - RHeel(t2f(LFS),1));

        %% Step time (per side): elapsed time from each heel strike to the next contralateral heel strike.
        RStepTime = NaN(size(RFS));
        for k = 1:numel(RFS)
            idx = find(LFS > RFS(k), 1, 'first');
            if ~isempty(idx), RStepTime(k) = LFS(idx) - RFS(k); end
        end
        LStepTime = NaN(size(LFS));
        for k = 1:numel(LFS)
            idx = find(RFS > LFS(k), 1, 'first');
            if ~isempty(idx), LStepTime(k) = RFS(idx) - LFS(k); end
        end

        %% Swing time (per side); NaN where no preceding toe-off exists
        RSwingT = NaN(size(RFS));
        for k = 1:numel(RFS)
            idx = find(RTO < RFS(k), 1, 'last');
            if ~isempty(idx), RSwingT(k) = RFS(k) - RTO(idx); end
        end
        LSwingT = NaN(size(LFS));
        for k = 1:numel(LFS)
            idx = find(LTO < LFS(k), 1, 'last');
            if ~isempty(idx), LSwingT(k) = LFS(k) - LTO(idx); end
        end

        %% Double support time (per side), referenced to each side's own
        % gait cycle: initial DS (weight acceptance) + terminal DS (pre-swing)

        % Right-referenced: initial DS = first left toe-off after RFS(i);
        % terminal DS = from first left heel strike within the cycle to
        % the next right toe-off
        RDblSupport = NaN(size(RFS));
        for i = 1:numel(RFS)-1
            cycleStart = RFS(i);
            cycleEnd   = RFS(i+1);

            idxTOopp = find(LTO > cycleStart & LTO < cycleEnd, 1, 'first');
            if isempty(idxTOopp), continue; end
            initDS = LTO(idxTOopp) - cycleStart;

            idxFSopp = find(LFS > cycleStart & LFS < cycleEnd, 1, 'first');
            if isempty(idxFSopp), continue; end
            fsOppTime = LFS(idxFSopp);

            idxTOside = find(RTO > fsOppTime & RTO < cycleEnd, 1, 'first');
            if isempty(idxTOside), continue; end
            termDS = RTO(idxTOside) - fsOppTime;

            RDblSupport(i) = initDS + termDS;
        end

        % Left-referenced: mirror of the above with sides swapped
        LDblSupport = NaN(size(LFS));
        for i = 1:numel(LFS)-1
            cycleStart = LFS(i);
            cycleEnd   = LFS(i+1);

            idxTOopp = find(RTO > cycleStart & RTO < cycleEnd, 1, 'first');
            if isempty(idxTOopp), continue; end
            initDS = RTO(idxTOopp) - cycleStart;

            idxFSopp = find(RFS > cycleStart & RFS < cycleEnd, 1, 'first');
            if isempty(idxFSopp), continue; end
            fsOppTime = RFS(idxFSopp);

            idxTOside = find(LTO > fsOppTime & LTO < cycleEnd, 1, 'first');
            if isempty(idxTOside), continue; end
            termDS = LTO(idxTOside) - fsOppTime;

            LDblSupport(i) = initDS + termDS;
        end

        %% Double support % and stance % (per side)
        RDblSupportPct = 100 * RDblSupport ./ RStrideTime;
        LDblSupportPct = 100 * LDblSupport ./ LStrideTime;
        RStancePct = 100 * (RStrideTime - RSwingT) ./ RStrideTime;
        LStancePct = 100 * (LStrideTime - LSwingT) ./ LStrideTime;

        % Trial-level metrics to repeat on every cycle row later.
        TrialDur_s = size(CoMVel,1) / FrameRate;
        TrialGaitSpeed = dirSign * median(CoMVel(:,1), 'omitnan');
        TrialCadence = (numel(RFS) + numel(LFS)) / TrialDur_s * 60;
        TrialPhi = NaN;
        TrialGaitSpeedVals(end+1) = TrialGaitSpeed;
        TrialCadenceVals(end+1) = TrialCadence;

        %% Kinematics: joint angles, segmented into per-stride cycles
        % Col 1 = X = sagittal, Col 2 = Y = frontal.
        % Left side is already sign-corrected at the V3D export stage (NEGATEY/NEGATEZ), so R and L use identical column logic here.
        RHipAng   = KinData.R_Hip_Ang{kIdx,1};
        LHipAng   = KinData.L_Hip_Ang{kIdx,1};
        RKneeAng  = KinData.R_Knee_Ang{kIdx,1};
        LKneeAng  = KinData.L_Knee_Ang{kIdx,1};
        RAnkleAng = KinData.R_Ankle_Ang{kIdx,1};
        LAnkleAng = KinData.L_Ankle_Ang{kIdx,1};
        TrunkAng  = KinData.Trunk_Ang{kIdx,1};

        % Flip (only) knee sign convention so that flexion is positive.
        RKneeAng(:,1) = -RKneeAng(:,1);
        LKneeAng(:,1) = -LKneeAng(:,1);

        % Right-side per-cycle kinematic peaks (bounded by RFS(i) to RFS(i+1))
        RHipPeakFlex = NaN(size(RFS)); RHipPeakExt = NaN(size(RFS));
        RHipPeakAdd  = NaN(size(RFS)); RHipPeakAbd = NaN(size(RFS));
        RHipPeakExtStance = NaN(size(RFS)); RHipPeakAddStance = NaN(size(RFS)); RHipPeakAbdStance = NaN(size(RFS));
        RHipSagROM   = NaN(size(RFS)); RHipFrontROM = NaN(size(RFS));
        RKneePeakFlex = NaN(size(RFS)); RKneePeakFlexStance = NaN(size(RFS)); RKneePeakFlexSwing = NaN(size(RFS)); RKneePeakExt = NaN(size(RFS));
        RKneePeakAdd  = NaN(size(RFS)); RKneePeakAbd = NaN(size(RFS));
        RKneeSagROM   = NaN(size(RFS)); RKneeFrontROM = NaN(size(RFS));
        RKneePeakAddStance = NaN(size(RFS)); RKneePeakAbdStance = NaN(size(RFS));
        RAnklePeakDorsi = NaN(size(RFS)); RAnklePeakPlantar = NaN(size(RFS)); RAnklePeakInv = NaN(size(RFS)); RAnklePeakEve = NaN(size(RFS));
        RAnkleSagROM = NaN(size(RFS)); RAnkleFrontROM = NaN(size(RFS));

        for i = 1:numel(RFS)-1
            seg = t2f(RFS(i)):t2f(RFS(i+1));

            RHipPeakFlex(i) = max(RHipAng(seg,1));
            RHipPeakExt(i)  = min(RHipAng(seg,1));
            RHipPeakAdd(i)  = max(RHipAng(seg,2));
            RHipPeakAbd(i)  = min(RHipAng(seg,2));
            RHipSagROM(i)   = RHipPeakFlex(i) - RHipPeakExt(i);
            RHipFrontROM(i) = RHipPeakAdd(i)  - RHipPeakAbd(i);

            RKneePeakFlex(i) = max(RKneeAng(seg,1));
            RKneePeakExt(i)  = min(RKneeAng(seg,1));
            RKneePeakAdd(i)  = max(RKneeAng(seg,2));
            RKneePeakAbd(i)  = min(RKneeAng(seg,2));
            RKneeSagROM(i)   = RKneePeakFlex(i) - RKneePeakExt(i);
            RKneeFrontROM(i) = RKneePeakAdd(i)  - RKneePeakAbd(i);

            toeOffIdx = find(RTO > RFS(i) & RTO < RFS(i+1), 1, 'first');
            if ~isempty(toeOffIdx)
                stanceEnd = t2f(RTO(toeOffIdx));
                earlyStanceSeg = t2f(RFS(i)):floor(t2f(RFS(i)) + 0.4 * (stanceEnd - t2f(RFS(i))));
                swingSeg = stanceEnd:t2f(RFS(i+1));
                stanceSeg = t2f(RFS(i)):stanceEnd; 
                if ~isempty(earlyStanceSeg), RKneePeakFlexStance(i) = max(RKneeAng(earlyStanceSeg,1)); end
                if ~isempty(swingSeg), RKneePeakFlexSwing(i) = max(RKneeAng(swingSeg,1)); end
                if ~isempty(stanceSeg)       
                    RHipPeakExtStance(i)  = min(RHipAng(stanceSeg,1));
                    RHipPeakAddStance(i)  = max(RHipAng(stanceSeg,2));
                    RHipPeakAbdStance(i)  = min(RHipAng(stanceSeg,2));
                    RKneePeakAddStance(i) = max(RKneeAng(stanceSeg,2));
                    RKneePeakAbdStance(i) = min(RKneeAng(stanceSeg,2));
                end
            end

            RAnklePeakDorsi(i)   = max(RAnkleAng(seg,1));
            RAnklePeakPlantar(i) = min(RAnkleAng(seg,1));
            RAnklePeakInv(i)     = max(RAnkleAng(seg,2));
            RAnklePeakEve(i)     = min(RAnkleAng(seg,2));
            RAnkleSagROM(i)      = RAnklePeakDorsi(i) - RAnklePeakPlantar(i);
            RAnkleFrontROM(i)    = RAnklePeakInv(i) - RAnklePeakEve(i);

            % Time-normalize this cycle's waveform to 0-100% GC (101 points)
            gcNorm  = linspace(0, 100, numel(seg));
            gcQuery = linspace(0, 100, 101);
            Pool.RHipSag     = [Pool.RHipSag,     interp1(gcNorm, RHipAng(seg,1),   gcQuery)'];
            Pool.RHipFront   = [Pool.RHipFront,   interp1(gcNorm, RHipAng(seg,2),   gcQuery)'];
            Pool.RKneeSag    = [Pool.RKneeSag,    interp1(gcNorm, RKneeAng(seg,1),  gcQuery)'];
            Pool.RKneeFront  = [Pool.RKneeFront,  interp1(gcNorm, RKneeAng(seg,2),  gcQuery)'];
            Pool.RAnkleSag   = [Pool.RAnkleSag,   interp1(gcNorm, RAnkleAng(seg,1), gcQuery)'];
            Pool.RAnkleFront = [Pool.RAnkleFront, interp1(gcNorm, RAnkleAng(seg,2), gcQuery)'];
        end

        % Left-side per-cycle kinematic peaks (bounded by LFS(i) to LFS(i+1))
        LHipPeakFlex = NaN(size(LFS)); LHipPeakExt = NaN(size(LFS));
        LHipPeakAdd  = NaN(size(LFS)); LHipPeakAbd = NaN(size(LFS));
        LHipSagROM   = NaN(size(LFS)); LHipFrontROM = NaN(size(LFS));
        LHipPeakExtStance = NaN(size(LFS)); LHipPeakAddStance = NaN(size(LFS)); LHipPeakAbdStance = NaN(size(LFS));
        LKneePeakFlex = NaN(size(LFS)); LKneePeakFlexStance = NaN(size(LFS)); LKneePeakFlexSwing = NaN(size(LFS)); LKneePeakExt = NaN(size(LFS));
        LKneePeakAdd  = NaN(size(LFS)); LKneePeakAbd = NaN(size(LFS));
        LKneeSagROM   = NaN(size(LFS)); LKneeFrontROM = NaN(size(LFS));
        LKneePeakAddStance = NaN(size(LFS)); LKneePeakAbdStance = NaN(size(LFS));
        LAnklePeakDorsi = NaN(size(LFS)); LAnklePeakPlantar = NaN(size(LFS)); LAnklePeakInv = NaN(size(LFS)); LAnklePeakEve = NaN(size(LFS));
        LAnkleSagROM = NaN(size(LFS)); LAnkleFrontROM = NaN(size(LFS));

        for i = 1:numel(LFS)-1
            seg = t2f(LFS(i)):t2f(LFS(i+1));

            LHipPeakFlex(i) = max(LHipAng(seg,1));
            LHipPeakExt(i)  = min(LHipAng(seg,1));
            LHipPeakAdd(i)  = max(LHipAng(seg,2));
            LHipPeakAbd(i)  = min(LHipAng(seg,2));
            LHipSagROM(i)   = LHipPeakFlex(i) - LHipPeakExt(i);
            LHipFrontROM(i) = LHipPeakAdd(i)  - LHipPeakAbd(i);

            LKneePeakFlex(i) = max(LKneeAng(seg,1));
            LKneePeakExt(i)  = min(LKneeAng(seg,1));
            LKneePeakAdd(i)  = max(LKneeAng(seg,2));
            LKneePeakAbd(i)  = min(LKneeAng(seg,2));
            LKneeSagROM(i)   = LKneePeakFlex(i) - LKneePeakExt(i);
            LKneeFrontROM(i) = LKneePeakAdd(i)  - LKneePeakAbd(i);

            toeOffIdx = find(LTO > LFS(i) & LTO < LFS(i+1), 1, 'first');
            if ~isempty(toeOffIdx)
                stanceEnd = t2f(LTO(toeOffIdx));
                earlyStanceSeg = t2f(LFS(i)):floor(t2f(LFS(i)) + 0.4 * (stanceEnd - t2f(LFS(i))));
                swingSeg = stanceEnd:t2f(LFS(i+1));
                stanceSeg = t2f(LFS(i)):stanceEnd;  
                if ~isempty(earlyStanceSeg), LKneePeakFlexStance(i) = max(LKneeAng(earlyStanceSeg,1)); end
                if ~isempty(swingSeg), LKneePeakFlexSwing(i) = max(LKneeAng(swingSeg,1)); end
                if ~isempty(stanceSeg)       
                    LHipPeakExtStance(i)  = min(LHipAng(stanceSeg,1));
                    LHipPeakAddStance(i)  = max(LHipAng(stanceSeg,2));
                    LHipPeakAbdStance(i)  = min(LHipAng(stanceSeg,2));
                    LKneePeakAddStance(i) = max(LKneeAng(stanceSeg,2));
                    LKneePeakAbdStance(i) = min(LKneeAng(stanceSeg,2));
                end
            end

            LAnklePeakDorsi(i)   = max(LAnkleAng(seg,1));
            LAnklePeakPlantar(i) = min(LAnkleAng(seg,1));
            LAnklePeakInv(i)     = max(LAnkleAng(seg,2));
            LAnklePeakEve(i)     = min(LAnkleAng(seg,2));
            LAnkleSagROM(i)      = LAnklePeakDorsi(i) - LAnklePeakPlantar(i);
            LAnkleFrontROM(i)    = LAnklePeakInv(i) - LAnklePeakEve(i);

            gcNorm  = linspace(0, 100, numel(seg));
            gcQuery = linspace(0, 100, 101);
            Pool.LHipSag     = [Pool.LHipSag,     interp1(gcNorm, LHipAng(seg,1),   gcQuery)'];
            Pool.LHipFront   = [Pool.LHipFront,   interp1(gcNorm, LHipAng(seg,2),   gcQuery)'];
            Pool.LKneeSag    = [Pool.LKneeSag,    interp1(gcNorm, LKneeAng(seg,1),  gcQuery)'];
            Pool.LKneeFront  = [Pool.LKneeFront,  interp1(gcNorm, LKneeAng(seg,2),  gcQuery)'];
            Pool.LAnkleSag   = [Pool.LAnkleSag,   interp1(gcNorm, LAnkleAng(seg,1), gcQuery)'];
            Pool.LAnkleFront = [Pool.LAnkleFront, interp1(gcNorm, LAnkleAng(seg,2), gcQuery)'];
        end

        %% Trunk kinematics (per trial, not per side/cycle).
        % Trunk_Ang is lab-referenced (segment vs VLB, same as Pelvis_Ang), so heading
        % affects its sign the same way it affects position data
        TrunkSagCorr   = dirSign * TrunkAng(:,1); % + = flexion
        TrunkFrontCorr = dirSign * TrunkAng(:,2); % lateral lean

        TrialTrunkPeakFlex = max(TrunkSagCorr);
        TrialTrunkPeakSway = max(abs(TrunkFrontCorr));

        Pool.TrunkPeakFlex = [Pool.TrunkPeakFlex; TrialTrunkPeakFlex];
        Pool.TrunkPeakSway = [Pool.TrunkPeakSway; TrialTrunkPeakSway];

        %% Cadence / gait speed accounting
        TrialDur_s = size(CoMVel,1) / FrameRate;
        Pool.TotalSteps  = Pool.TotalSteps + numel(RFS) + numel(LFS);
        Pool.TotalTime_s = Pool.TotalTime_s + TrialDur_s;
        Pool.GaitSpeed   = [Pool.GaitSpeed; dirSign * CoMVel(:,1)];

        %% Pool everything 
        % trial boundaries never crossed: all diff()/
        % pairing/DS calcs above are computed independently per trial,
        % before concatenation onto the subject-level pool
        Pool.RSwing       = [Pool.RSwing;       RSwingT(:)];
        Pool.LSwing       = [Pool.LSwing;       LSwingT(:)];
        Pool.RStrideLen   = [Pool.RStrideLen;   RStrideLen];
        Pool.LStrideLen   = [Pool.LStrideLen;   LStrideLen];
        Pool.RStrideTime  = [Pool.RStrideTime;  RStrideTime];
        Pool.LStrideTime  = [Pool.LStrideTime;  LStrideTime];
        Pool.RStepLen     = [Pool.RStepLen;     RStepLen];
        Pool.LStepLen     = [Pool.LStepLen;     LStepLen];
        Pool.RStepTime    = [Pool.RStepTime;    RStepTime];
        Pool.LStepTime    = [Pool.LStepTime;    LStepTime];
        Pool.RDblSupport  = [Pool.RDblSupport;  RDblSupport];
        Pool.LDblSupport  = [Pool.LDblSupport;  LDblSupport];
        Pool.RDblSupportPct = [Pool.RDblSupportPct; RDblSupportPct];
        Pool.LDblSupportPct = [Pool.LDblSupportPct; LDblSupportPct];
        Pool.RStancePct   = [Pool.RStancePct;   RStancePct];
        Pool.LStancePct   = [Pool.LStancePct;   LStancePct];

        Pool.RHipPeakFlex = [Pool.RHipPeakFlex; RHipPeakFlex]; Pool.LHipPeakFlex = [Pool.LHipPeakFlex; LHipPeakFlex];
        Pool.RHipPeakExt  = [Pool.RHipPeakExt;  RHipPeakExt];  Pool.LHipPeakExt  = [Pool.LHipPeakExt;  LHipPeakExt];
        Pool.RHipPeakExtStance = [Pool.RHipPeakExtStance; RHipPeakExtStance]; Pool.LHipPeakExtStance = [Pool.LHipPeakExtStance; LHipPeakExtStance];
        Pool.RHipPeakAdd  = [Pool.RHipPeakAdd;  RHipPeakAdd];  Pool.LHipPeakAdd  = [Pool.LHipPeakAdd;  LHipPeakAdd];
        Pool.RHipPeakAbd  = [Pool.RHipPeakAbd;  RHipPeakAbd];  Pool.LHipPeakAbd  = [Pool.LHipPeakAbd;  LHipPeakAbd];
        Pool.RHipPeakAddStance = [Pool.RHipPeakAddStance; RHipPeakAddStance]; Pool.LHipPeakAddStance = [Pool.LHipPeakAddStance; LHipPeakAddStance];
        Pool.RHipPeakAbdStance = [Pool.RHipPeakAbdStance; RHipPeakAbdStance]; Pool.LHipPeakAbdStance = [Pool.LHipPeakAbdStance; LHipPeakAbdStance];
        Pool.RHipSagROM   = [Pool.RHipSagROM;   RHipSagROM];   Pool.LHipSagROM   = [Pool.LHipSagROM;   LHipSagROM];
        Pool.RHipFrontROM = [Pool.RHipFrontROM; RHipFrontROM]; Pool.LHipFrontROM = [Pool.LHipFrontROM; LHipFrontROM];

        Pool.RKneePeakFlex = [Pool.RKneePeakFlex; RKneePeakFlex]; Pool.LKneePeakFlex = [Pool.LKneePeakFlex; LKneePeakFlex];
        Pool.RKneePeakFlexStance = [Pool.RKneePeakFlexStance; RKneePeakFlexStance]; Pool.LKneePeakFlexStance = [Pool.LKneePeakFlexStance; LKneePeakFlexStance];
        Pool.RKneePeakFlexSwing = [Pool.RKneePeakFlexSwing; RKneePeakFlexSwing]; Pool.LKneePeakFlexSwing = [Pool.LKneePeakFlexSwing; LKneePeakFlexSwing];
        Pool.RKneePeakExt  = [Pool.RKneePeakExt;  RKneePeakExt];  Pool.LKneePeakExt  = [Pool.LKneePeakExt;  LKneePeakExt];
        Pool.RKneePeakAdd  = [Pool.RKneePeakAdd;  RKneePeakAdd];  Pool.LKneePeakAdd  = [Pool.LKneePeakAdd;  LKneePeakAdd];
        Pool.RKneePeakAbd  = [Pool.RKneePeakAbd;  RKneePeakAbd];  Pool.LKneePeakAbd  = [Pool.LKneePeakAbd;  LKneePeakAbd];
        Pool.RKneePeakAddStance = [Pool.RKneePeakAddStance; RKneePeakAddStance]; Pool.LKneePeakAddStance = [Pool.LKneePeakAddStance; LKneePeakAddStance];
        Pool.RKneePeakAbdStance = [Pool.RKneePeakAbdStance; RKneePeakAbdStance]; Pool.LKneePeakAbdStance = [Pool.LKneePeakAbdStance; LKneePeakAbdStance];
        Pool.RKneeSagROM   = [Pool.RKneeSagROM;   RKneeSagROM];   Pool.LKneeSagROM   = [Pool.LKneeSagROM;   LKneeSagROM];
        Pool.RKneeFrontROM = [Pool.RKneeFrontROM; RKneeFrontROM]; Pool.LKneeFrontROM = [Pool.LKneeFrontROM; LKneeFrontROM];

        Pool.RAnklePeakDorsi   = [Pool.RAnklePeakDorsi;   RAnklePeakDorsi];   Pool.LAnklePeakDorsi   = [Pool.LAnklePeakDorsi;   LAnklePeakDorsi];
        Pool.RAnklePeakPlantar = [Pool.RAnklePeakPlantar; RAnklePeakPlantar]; Pool.LAnklePeakPlantar = [Pool.LAnklePeakPlantar; LAnklePeakPlantar];
        Pool.RAnklePeakInv     = [Pool.RAnklePeakInv;     RAnklePeakInv];     Pool.LAnklePeakInv     = [Pool.LAnklePeakInv;     LAnklePeakInv];
        Pool.RAnklePeakEve     = [Pool.RAnklePeakEve;     RAnklePeakEve];     Pool.LAnklePeakEve     = [Pool.LAnklePeakEve;     LAnklePeakEve];
        Pool.RAnkleSagROM      = [Pool.RAnkleSagROM;      RAnkleSagROM];      Pool.LAnkleSagROM      = [Pool.LAnkleSagROM;      LAnkleSagROM];
        Pool.RAnkleFrontROM    = [Pool.RAnkleFrontROM;    RAnkleFrontROM];    Pool.LAnkleFrontROM    = [Pool.LAnkleFrontROM;    LAnkleFrontROM];

        %% Build this trial's per-cycle rows (both sides). 
        % Trunk values are per-trial, so they're repeated across all rows for this trial.
        nR = numel(RFS); nL = numel(LFS);

        % Diagnostic check: confirm every per-cycle array actually has nR
        % (or nL) elements before handing them to table(). If this fires,
        % the printed name/count tells you exactly which variable and
        % which trial is out of sync.
        RCheck = struct('RStrideLen',RStrideLen,'RStrideTime',RStrideTime,'RStepLen',RStepLen,'RStepTime',RStepTime,'RDblSupport',RDblSupport,'RDblSupportPct',RDblSupportPct,'RStancePct',RStancePct,'RSwingT',RSwingT, ...
            'RHipPeakFlex',RHipPeakFlex,'RHipPeakExt',RHipPeakExt,'RHipPeakAdd',RHipPeakAdd, ...
            'RHipPeakAbd',RHipPeakAbd,'RHipSagROM',RHipSagROM,'RHipFrontROM',RHipFrontROM, ...
            'RHipPeakExtStance',RHipPeakExtStance,'RHipPeakAddStance',RHipPeakAddStance,'RHipPeakAbdStance',RHipPeakAbdStance,'RKneePeakAddStance',RKneePeakAddStance,'RKneePeakAbdStance',RKneePeakAbdStance, ...
            'RKneePeakFlex',RKneePeakFlex,'RKneePeakFlexStance',RKneePeakFlexStance,'RKneePeakFlexSwing',RKneePeakFlexSwing,'RKneePeakExt',RKneePeakExt,'RKneePeakAdd',RKneePeakAdd, ...
            'RKneePeakAbd',RKneePeakAbd,'RKneeSagROM',RKneeSagROM,'RKneeFrontROM',RKneeFrontROM, ...
            'RAnklePeakDorsi',RAnklePeakDorsi,'RAnklePeakPlantar',RAnklePeakPlantar,'RAnklePeakInv',RAnklePeakInv,'RAnklePeakEve',RAnklePeakEve,'RAnkleSagROM',RAnkleSagROM,'RAnkleFrontROM',RAnkleFrontROM);
        fn = fieldnames(RCheck);
        for v = 1:numel(fn)
            if numel(RCheck.(fn{v})) ~= nR
                error('Row mismatch: %s has %d elements but nR=%d for %s, trial %s.', ...
                    fn{v}, numel(RCheck.(fn{v})), nR, Subj, TrialName);
            end
        end

        LCheck = struct('LStrideLen',LStrideLen,'LStrideTime',LStrideTime,'LStepLen',LStepLen,'LStepTime',LStepTime,'LDblSupport',LDblSupport,'LDblSupportPct',LDblSupportPct,'LStancePct',LStancePct,'LSwingT',LSwingT, ...
            'LHipPeakFlex',LHipPeakFlex,'LHipPeakExt',LHipPeakExt,'LHipPeakAdd',LHipPeakAdd, ...
            'LHipPeakAbd',LHipPeakAbd,'LHipSagROM',LHipSagROM,'LHipFrontROM',LHipFrontROM, ...
            'LHipPeakExtStance',LHipPeakExtStance,'LHipPeakAddStance',LHipPeakAddStance,'LHipPeakAbdStance',LHipPeakAbdStance,'LKneePeakAddStance',LKneePeakAddStance,'LKneePeakAbdStance',LKneePeakAbdStance, ...
            'LKneePeakFlex',LKneePeakFlex,'LKneePeakFlexStance',LKneePeakFlexStance,'LKneePeakFlexSwing',LKneePeakFlexSwing,'LKneePeakExt',LKneePeakExt,'LKneePeakAdd',LKneePeakAdd, ...
            'LKneePeakAbd',LKneePeakAbd,'LKneeSagROM',LKneeSagROM,'LKneeFrontROM',LKneeFrontROM, ...
            'LAnklePeakDorsi',LAnklePeakDorsi,'LAnklePeakPlantar',LAnklePeakPlantar,'LAnklePeakInv',LAnklePeakInv,'LAnklePeakEve',LAnklePeakEve,'LAnkleSagROM',LAnkleSagROM,'LAnkleFrontROM',LAnkleFrontROM);
        fn = fieldnames(LCheck);
        for v = 1:numel(fn)
            if numel(LCheck.(fn{v})) ~= nL
                error('Row mismatch: %s has %d elements but nL=%d for %s, trial %s.', ...
                    fn{v}, numel(LCheck.(fn{v})), nL, Subj, TrialName);
            end
        end

        if numel(TrialTrunkPeakFlex) ~= 1 || numel(TrialTrunkPeakSway) ~= 1
            error('TrunkPeak values are not scalar for %s, trial %s (check Trunk_Ang is not empty).', Subj, TrialName);
        end

        if strcmp(uninvolvedSideCode, 'L')
            UStrideLen = LStrideLen; IStrideLen = RStrideLen;
            UStrideTime = LStrideTime; IStrideTime = RStrideTime;
            UStepLen = LStepLen; IStepLen = RStepLen;
            UStepTime = LStepTime; IStepTime = RStepTime;
            UDoubleSupportPct = LDblSupportPct; IDoubleSupportPct = RDblSupportPct;
            UStancePct = LStancePct; IStancePct = RStancePct;
            UHipPeakFlex = LHipPeakFlex; IHipPeakFlex = RHipPeakFlex;
            UHipPeakExt = LHipPeakExt; IHipPeakExt = RHipPeakExt;
            UHipPeakAdd = LHipPeakAdd; IHipPeakAdd = RHipPeakAdd;
            UHipPeakAbd = LHipPeakAbd; IHipPeakAbd = RHipPeakAbd;
            UHipSagROM = LHipSagROM; IHipSagROM = RHipSagROM;
            UHipFrontROM = LHipFrontROM; IHipFrontROM = RHipFrontROM;
            UKneePeakFlex = LKneePeakFlex; IKneePeakFlex = RKneePeakFlex;
            UKneePeakFlexStance = LKneePeakFlexStance; IKneePeakFlexStance = RKneePeakFlexStance;
            UKneePeakFlexSwing = LKneePeakFlexSwing; IKneePeakFlexSwing = RKneePeakFlexSwing;
            UKneePeakExt = LKneePeakExt; IKneePeakExt = RKneePeakExt;
            UKneePeakAdd = LKneePeakAdd; IKneePeakAdd = RKneePeakAdd;
            UKneePeakAbd = LKneePeakAbd; IKneePeakAbd = RKneePeakAbd;
            UKneeSagROM = LKneeSagROM; IKneeSagROM = RKneeSagROM;
            UKneeFrontROM = LKneeFrontROM; IKneeFrontROM = RKneeFrontROM;
            UAnklePeakDorsi = LAnklePeakDorsi; IAnklePeakDorsi = RAnklePeakDorsi;
            UAnklePeakPlantar = LAnklePeakPlantar; IAnklePeakPlantar = RAnklePeakPlantar;
            UAnklePeakInv = LAnklePeakInv; IAnklePeakInv = RAnklePeakInv;
            UAnklePeakEve = LAnklePeakEve; IAnklePeakEve = RAnklePeakEve;
            UAnkleSagROM = LAnkleSagROM; IAnkleSagROM = RAnkleSagROM;
            UAnkleFrontROM = LAnkleFrontROM; IAnkleFrontROM = RAnkleFrontROM;
            UHipPeakExtStance = LHipPeakExtStance; IHipPeakExtStance = RHipPeakExtStance;
            UHipPeakAddStance = LHipPeakAddStance; IHipPeakAddStance = RHipPeakAddStance;
            UHipPeakAbdStance = LHipPeakAbdStance; IHipPeakAbdStance = RHipPeakAbdStance;
            UKneePeakAddStance = LKneePeakAddStance; IKneePeakAddStance = RKneePeakAddStance;
            UKneePeakAbdStance = LKneePeakAbdStance; IKneePeakAbdStance = RKneePeakAbdStance;
        else
            UStrideLen = RStrideLen; IStrideLen = LStrideLen;
            UStrideTime = RStrideTime; IStrideTime = LStrideTime;
            UStepLen = RStepLen; IStepLen = LStepLen;
            UStepTime = RStepTime; IStepTime = LStepTime;
            UDoubleSupportPct = RDblSupportPct; IDoubleSupportPct = LDblSupportPct;
            UStancePct = RStancePct; IStancePct = LStancePct;
            UHipPeakFlex = RHipPeakFlex; IHipPeakFlex = LHipPeakFlex;
            UHipPeakExt = RHipPeakExt; IHipPeakExt = LHipPeakExt;
            UHipPeakAdd = RHipPeakAdd; IHipPeakAdd = LHipPeakAdd;
            UHipPeakAbd = RHipPeakAbd; IHipPeakAbd = LHipPeakAbd;
            UHipSagROM = RHipSagROM; IHipSagROM = LHipSagROM;
            UHipFrontROM = RHipFrontROM; IHipFrontROM = LHipFrontROM;
            UKneePeakFlex = RKneePeakFlex; IKneePeakFlex = LKneePeakFlex;
            UKneePeakFlexStance = RKneePeakFlexStance; IKneePeakFlexStance = LKneePeakFlexStance;
            UKneePeakFlexSwing = RKneePeakFlexSwing; IKneePeakFlexSwing = LKneePeakFlexSwing;
            UKneePeakExt = RKneePeakExt; IKneePeakExt = LKneePeakExt;
            UKneePeakAdd = RKneePeakAdd; IKneePeakAdd = LKneePeakAdd;
            UKneePeakAbd = RKneePeakAbd; IKneePeakAbd = LKneePeakAbd;
            UKneeSagROM = RKneeSagROM; IKneeSagROM = LKneeSagROM;
            UKneeFrontROM = RKneeFrontROM; IKneeFrontROM = LKneeFrontROM;
            UAnklePeakDorsi = RAnklePeakDorsi; IAnklePeakDorsi = LAnklePeakDorsi;
            UAnklePeakPlantar = RAnklePeakPlantar; IAnklePeakPlantar = LAnklePeakPlantar;
            UAnklePeakInv = RAnklePeakInv; IAnklePeakInv = LAnklePeakInv;
            UAnklePeakEve = RAnklePeakEve; IAnklePeakEve = LAnklePeakEve;
            UAnkleSagROM = RAnkleSagROM; IAnkleSagROM = LAnkleSagROM;
            UAnkleFrontROM = RAnkleFrontROM; IAnkleFrontROM = LAnkleFrontROM;
            UHipPeakExtStance = RHipPeakExtStance; IHipPeakExtStance = LHipPeakExtStance;
            UHipPeakAddStance = RHipPeakAddStance; IHipPeakAddStance = LHipPeakAddStance;
            UHipPeakAbdStance = RHipPeakAbdStance; IHipPeakAbdStance = LHipPeakAbdStance;
            UKneePeakAddStance = RKneePeakAddStance; IKneePeakAddStance = LKneePeakAddStance;
            UKneePeakAbdStance = RKneePeakAbdStance; IKneePeakAbdStance = LKneePeakAbdStance;
        end

        % The uninvolved and involved limbs can legitimately have different
        % numbers of detected cycles in a trial, so each limb is exported
        % independently rather than forced to have the same row count.
        nU = numel(UStrideLen); nI = numel(IStrideLen);

        trialRowStart = height(SubjCycleTable) + 1;

        % These are trial-level metrics, but each cycle row in the cycle table
        % should carry the same values for that trial's cycle block.
        UGaitSpeed = repmat(TrialGaitSpeed,nU,1);
        UCadence = repmat(TrialCadence,nU,1);
        UPhi = repmat(TrialPhi,nU,1);
        IGaitSpeed = repmat(TrialGaitSpeed,nI,1);
        ICadence = repmat(TrialCadence,nI,1);
        IPhi = repmat(TrialPhi,nI,1);

        URows = table(repmat({Subj},nU,1), repmat(TrialNum,nU,1), repmat({'Uninvolved'},nU,1), (1:nU)', ...
            UGaitSpeed, UCadence, UPhi, ...
            UStrideLen, UStrideTime, UStepLen, UStepTime, UDoubleSupportPct, UStancePct, ...
            UHipPeakFlex, UHipPeakExt, UHipPeakAdd, UHipPeakAbd, UHipSagROM, UHipFrontROM, UHipPeakExtStance, UHipPeakAddStance, UHipPeakAbdStance, ...
            UKneePeakFlex, UKneePeakFlexStance, UKneePeakFlexSwing, UKneePeakExt, UKneePeakAdd, UKneePeakAbd, UKneePeakAddStance, UKneePeakAbdStance, UKneeSagROM, UKneeFrontROM, ...
            UAnklePeakDorsi, UAnklePeakPlantar, UAnklePeakInv, UAnklePeakEve, UAnkleSagROM, UAnkleFrontROM, ...
            repmat(TrialTrunkPeakFlex,nU,1), repmat(TrialTrunkPeakSway,nU,1), ...
            'VariableNames', {'Participant','Trial','Limb','GaitCycle','GaitSpeed','Cadence','Phi','StrideLength','StrideTime','StepLength','StepTime','DoubleSupportPct','StancePct', ...
            'HipPeakFlex','HipPeakExt','HipPeakAdd','HipPeakAbd','HipSagROM','HipFrontROM', 'HipPeakExtensionStance','HipPeakAddStance','HipPeakAbdStance', ...
            'KneePeakFlex','KneePeakFlexionEarlyStance','KneePeakFlexSwing','KneePeakExt','KneePeakAdd','KneePeakAbd','KneePeakAddStance','KneePeakAbdStance','KneeSagROM','KneeFrontROM', ...
            'AnklePeakDorsi','AnklePeakPlantar','AnklePeakInversion','AnklePeakEversion','AnkleSagROM','AnkleFrontROM','TrunkPeakFlex','TrunkPeakSway'});
        IRows = table(repmat({Subj},nI,1), repmat(TrialNum,nI,1), repmat({'Involved'},nI,1), (1:nI)', ...
            IGaitSpeed, ICadence, IPhi, ...
            IStrideLen, IStrideTime, IStepLen, IStepTime, IDoubleSupportPct, IStancePct, ...
            IHipPeakFlex, IHipPeakExt, IHipPeakAdd, IHipPeakAbd, IHipSagROM, IHipFrontROM, IHipPeakExtStance, IHipPeakAddStance, IHipPeakAbdStance,  ...
            IKneePeakFlex, IKneePeakFlexStance, IKneePeakFlexSwing, IKneePeakExt, IKneePeakAdd, IKneePeakAbd, IKneePeakAddStance, IKneePeakAbdStance,IKneeSagROM, IKneeFrontROM, ...
            IAnklePeakDorsi, IAnklePeakPlantar, IAnklePeakInv, IAnklePeakEve, IAnkleSagROM, IAnkleFrontROM, ...
            repmat(TrialTrunkPeakFlex,nI,1), repmat(TrialTrunkPeakSway,nI,1), ...
            'VariableNames', {'Participant','Trial','Limb','GaitCycle','GaitSpeed','Cadence','Phi','StrideLength','StrideTime','StepLength','StepTime','DoubleSupportPct','StancePct', ...
            'HipPeakFlex','HipPeakExt','HipPeakAdd','HipPeakAbd','HipSagROM','HipFrontROM', 'HipPeakExtensionStance','HipPeakAddStance','HipPeakAbdStance' ...
            'KneePeakFlex','KneePeakFlexionEarlyStance','KneePeakFlexSwing','KneePeakExt','KneePeakAdd','KneePeakAbd','KneePeakAddStance','KneePeakAbdStance','KneeSagROM','KneeFrontROM', ...
            'AnklePeakDorsi','AnklePeakPlantar','AnklePeakInversion','AnklePeakEversion','AnkleSagROM','AnkleFrontROM','TrunkPeakFlex','TrunkPeakSway'});

        SubjCycleTable = [SubjCycleTable; URows; IRows];
        TrialRowRanges{end+1} = trialRowStart:height(SubjCycleTable);
    end

    %% ---- Phase Coordination Index ----
    % Determine short vs. long swing side once, from pooled swing times
    % (per Plotnik et al. 2007), then compute phi per trial
    ShortSideIsR = mean(Pool.RSwing, 'omitnan') < mean(Pool.LSwing, 'omitnan');

    Pool.Phi = [];
    for t = 1:numel(EventsTrialIdx)
        eIdx = EventsTrialIdx(t);

        LFS = EventsData.LHS{eIdx,1}; LFS = LFS(:);
        RFS = EventsData.RHS{eIdx,1}; RFS = RFS(:);

        if ShortSideIsR
            ShortFS = RFS; LongFS = LFS;
        else
            ShortFS = LFS; LongFS = RFS;
        end

        Phi = NaN(1, numel(LongFS)-1);
        for k = 1:numel(LongFS)-1
            tLi  = LongFS(k);
            tLi1 = LongFS(k+1);
            tSi  = ShortFS(ShortFS > tLi & ShortFS < tLi1);
            if ~isempty(tSi)
                Phi(k) = 360 * (tSi(1) - tLi) / (tLi1 - tLi);
            end
        end
        Pool.Phi = [Pool.Phi, Phi]; 
    end

    Pool.Phi = Pool.Phi(~isnan(Pool.Phi));

    for t = 1:numel(TrialRowRanges)
        eIdx = ProcessedEventIdx(t);
        LFS = EventsData.LHS{eIdx,1}; LFS = LFS(:);
        RFS = EventsData.RHS{eIdx,1}; RFS = RFS(:);

        if ShortSideIsR
            ShortFS = RFS; LongFS = LFS;
        else
            ShortFS = LFS; LongFS = RFS;
        end

        Phi = NaN(1, numel(LongFS)-1);
        for k = 1:numel(LongFS)-1
            tLi  = LongFS(k);
            tLi1 = LongFS(k+1);
            tSi  = ShortFS(ShortFS > tLi & ShortFS < tLi1);
            if ~isempty(tSi)
                Phi(k) = 360 * (tSi(1) - tLi) / (tLi1 - tLi);
            end
        end
        TrialPhiVals(t) = mean(Phi, 'omitnan');
        TrialPhiCycleVals{t} = Phi;
    end

    for t = 1:numel(TrialRowRanges)
        if ~isempty(TrialRowRanges{t})
            rowIdx = TrialRowRanges{t};
            rowCount = numel(rowIdx);
            phiVals = TrialPhiCycleVals{t};
            if numel(phiVals) >= rowCount
                phiVals = phiVals(1:rowCount);
            else
                phiVals = [phiVals, NaN(1, rowCount - numel(phiVals))];
            end
            SubjCycleTable.GaitSpeed(rowIdx) = TrialGaitSpeedVals(t);
            SubjCycleTable.Cadence(rowIdx) = TrialCadenceVals(t);
            SubjCycleTable.Phi(rowIdx) = phiVals(:);
        end
    end

    PhiDiff  = abs(Pool.Phi - 180);         % absolute difference of phi values
    PhiAbs   = mean(PhiDiff);               % mean value of absolute differences (degrees)
    P_PhiAbs = 100 * PhiAbs / 180;          % percentage-converted PhiAbs (%)
    PhiCV    = (std(Pool.Phi) / mean(Pool.Phi)) * 100; % coefficient of variation of phi (%)
    PCI      = PhiCV + P_PhiAbs;
    PhiMean  = mean(Pool.Phi);

    %% ---- Subject-level summary row ----
    Cadence   = (Pool.TotalSteps / Pool.TotalTime_s) * 60; % steps/min, pooled across trials
    GaitSpeed = mean(Pool.GaitSpeed, 'omitnan');            % mm/s, pooled across trials

    if strcmp(uninvolvedSideCode, 'L')
        UStrideLenMean = mean(Pool.LStrideLen, 'omitnan'); IStrideLenMean = mean(Pool.RStrideLen, 'omitnan');
        UStrideTimeMean = mean(Pool.LStrideTime, 'omitnan'); IStrideTimeMean = mean(Pool.RStrideTime, 'omitnan');
        UStepLenMean = mean(Pool.LStepLen, 'omitnan'); IStepLenMean = mean(Pool.RStepLen, 'omitnan');
        UStepTimeMean = mean(Pool.LStepTime, 'omitnan'); IStepTimeMean = mean(Pool.RStepTime, 'omitnan');
        UDoubleSupportPctMean = mean(Pool.LDblSupportPct, 'omitnan'); IDoubleSupportPctMean = mean(Pool.RDblSupportPct, 'omitnan');
        UStancePctMean = mean(Pool.LStancePct, 'omitnan'); IStancePctMean = mean(Pool.RStancePct, 'omitnan');
        UNcycles = numel(Pool.LStrideLen); INcycles = numel(Pool.RStrideLen);
        UHipsFlexMean = mean(Pool.LHipPeakFlex, 'omitnan'); IHipsFlexMean = mean(Pool.RHipPeakFlex, 'omitnan');
        UHipsExtMean = mean(Pool.LHipPeakExt, 'omitnan'); IHipsExtMean = mean(Pool.RHipPeakExt, 'omitnan');
        UHipsSagROMMean = mean(Pool.LHipSagROM, 'omitnan'); IHipsSagROMMean = mean(Pool.RHipSagROM, 'omitnan');
        UHipsAbdMean = mean(Pool.LHipPeakAbd, 'omitnan'); IHipsAbdMean = mean(Pool.RHipPeakAbd, 'omitnan');
        UHipsAddMean = mean(Pool.LHipPeakAdd, 'omitnan'); IHipsAddMean = mean(Pool.RHipPeakAdd, 'omitnan');
        UHipsFrontROMMean = mean(Pool.LHipFrontROM, 'omitnan'); IHipsFrontROMMean = mean(Pool.RHipFrontROM, 'omitnan');
        UKneeFlexStanceMean = mean(Pool.LKneePeakFlexStance, 'omitnan'); IKneeFlexStanceMean = mean(Pool.RKneePeakFlexStance, 'omitnan');
        UKneeFlexSwingMean = mean(Pool.LKneePeakFlexSwing, 'omitnan'); IKneeFlexSwingMean = mean(Pool.RKneePeakFlexSwing, 'omitnan');
        UKneeExtMean = mean(Pool.LKneePeakExt, 'omitnan'); IKneeExtMean = mean(Pool.RKneePeakExt, 'omitnan');
        UKneeSagROMMean = mean(Pool.LKneeSagROM, 'omitnan'); IKneeSagROMMean = mean(Pool.RKneeSagROM, 'omitnan');
        UKneeAbdMean = mean(Pool.LKneePeakAbd, 'omitnan'); IKneeAbdMean = mean(Pool.RKneePeakAbd, 'omitnan');
        UKneeAddMean = mean(Pool.LKneePeakAdd, 'omitnan'); IKneeAddMean = mean(Pool.RKneePeakAdd, 'omitnan');
        UKneeFrontROMMean = mean(Pool.LKneeFrontROM, 'omitnan'); IKneeFrontROMMean = mean(Pool.RKneeFrontROM, 'omitnan');
        UAnkleDorsiMean = mean(Pool.LAnklePeakDorsi, 'omitnan'); IAnkleDorsiMean = mean(Pool.RAnklePeakDorsi, 'omitnan');
        UAnklePlantarMean = mean(Pool.LAnklePeakPlantar, 'omitnan'); IAnklePlantarMean = mean(Pool.RAnklePeakPlantar, 'omitnan');
        UAnkleSagROMMean = mean(Pool.LAnkleSagROM, 'omitnan'); IAnkleSagROMMean = mean(Pool.RAnkleSagROM, 'omitnan');
        UAnkleInvMean = mean(Pool.LAnklePeakInv, 'omitnan'); IAnkleInvMean = mean(Pool.RAnklePeakInv, 'omitnan');
        UAnkleEveMean = mean(Pool.LAnklePeakEve, 'omitnan'); IAnkleEveMean = mean(Pool.RAnklePeakEve, 'omitnan');
        UAnkleFrontROMMean = mean(Pool.LAnkleFrontROM, 'omitnan'); IAnkleFrontROMMean = mean(Pool.RAnkleFrontROM, 'omitnan');
        UHipExtStanceMean = mean(Pool.LHipPeakExtStance,'omitnan'); IHipExtStanceMean = mean(Pool.RHipPeakExtStance,'omitnan');
        UHipAddStanceMean = mean(Pool.LHipPeakAddStance,'omitnan'); IHipAddStanceMean = mean(Pool.RHipPeakAddStance,'omitnan');
        UHipAbdStanceMean = mean(Pool.LHipPeakAbdStance,'omitnan'); IHipAbdStanceMean = mean(Pool.RHipPeakAbdStance,'omitnan');
        UKneeAddStanceMean = mean(Pool.LKneePeakAddStance,'omitnan'); IKneeAddStanceMean = mean(Pool.RKneePeakAddStance,'omitnan');
        UKneeAbdStanceMean = mean(Pool.LKneePeakAbdStance,'omitnan'); IKneeAbdStanceMean = mean(Pool.RKneePeakAbdStance,'omitnan');
    else
        UStrideLenMean = mean(Pool.RStrideLen, 'omitnan'); IStrideLenMean = mean(Pool.LStrideLen, 'omitnan');
        UStrideTimeMean = mean(Pool.RStrideTime, 'omitnan'); IStrideTimeMean = mean(Pool.LStrideTime, 'omitnan');
        UStepLenMean = mean(Pool.RStepLen, 'omitnan'); IStepLenMean = mean(Pool.LStepLen, 'omitnan');
        UStepTimeMean = mean(Pool.RStepTime, 'omitnan'); IStepTimeMean = mean(Pool.LStepTime, 'omitnan');
        UDoubleSupportPctMean = mean(Pool.RDblSupportPct, 'omitnan'); IDoubleSupportPctMean = mean(Pool.LDblSupportPct, 'omitnan');
        UStancePctMean = mean(Pool.RStancePct, 'omitnan'); IStancePctMean = mean(Pool.LStancePct, 'omitnan');
        UNcycles = numel(Pool.RStrideLen); INcycles = numel(Pool.LStrideLen);
        UHipsFlexMean = mean(Pool.RHipPeakFlex, 'omitnan'); IHipsFlexMean = mean(Pool.LHipPeakFlex, 'omitnan');
        UHipsExtMean = mean(Pool.RHipPeakExt, 'omitnan'); IHipsExtMean = mean(Pool.LHipPeakExt, 'omitnan');
        UHipsSagROMMean = mean(Pool.RHipSagROM, 'omitnan'); IHipsSagROMMean = mean(Pool.LHipSagROM, 'omitnan');
        UHipsAbdMean = mean(Pool.RHipPeakAbd, 'omitnan'); IHipsAbdMean = mean(Pool.LHipPeakAbd, 'omitnan');
        UHipsAddMean = mean(Pool.RHipPeakAdd, 'omitnan'); IHipsAddMean = mean(Pool.LHipPeakAdd, 'omitnan');
        UHipsFrontROMMean = mean(Pool.RHipFrontROM, 'omitnan'); IHipsFrontROMMean = mean(Pool.LHipFrontROM, 'omitnan');
        UKneeFlexStanceMean = mean(Pool.RKneePeakFlexStance, 'omitnan'); IKneeFlexStanceMean = mean(Pool.LKneePeakFlexStance, 'omitnan');
        UKneeFlexSwingMean = mean(Pool.RKneePeakFlexSwing, 'omitnan'); IKneeFlexSwingMean = mean(Pool.LKneePeakFlexSwing, 'omitnan');
        UKneeExtMean = mean(Pool.RKneePeakExt, 'omitnan'); IKneeExtMean = mean(Pool.LKneePeakExt, 'omitnan');
        UKneeSagROMMean = mean(Pool.RKneeSagROM, 'omitnan'); IKneeSagROMMean = mean(Pool.LKneeSagROM, 'omitnan');
        UKneeAbdMean = mean(Pool.RKneePeakAbd, 'omitnan'); IKneeAbdMean = mean(Pool.LKneePeakAbd, 'omitnan');
        UKneeAddMean = mean(Pool.RKneePeakAdd, 'omitnan'); IKneeAddMean = mean(Pool.LKneePeakAdd, 'omitnan');
        UKneeFrontROMMean = mean(Pool.RKneeFrontROM, 'omitnan'); IKneeFrontROMMean = mean(Pool.LKneeFrontROM, 'omitnan');
        UAnkleDorsiMean = mean(Pool.RAnklePeakDorsi, 'omitnan'); IAnkleDorsiMean = mean(Pool.LAnklePeakDorsi, 'omitnan');
        UAnklePlantarMean = mean(Pool.RAnklePeakPlantar, 'omitnan'); IAnklePlantarMean = mean(Pool.LAnklePeakPlantar, 'omitnan');
        UAnkleSagROMMean = mean(Pool.RAnkleSagROM, 'omitnan'); IAnkleSagROMMean = mean(Pool.LAnkleSagROM, 'omitnan');
        UAnkleInvMean = mean(Pool.RAnklePeakInv, 'omitnan'); IAnkleInvMean = mean(Pool.LAnklePeakInv, 'omitnan');
        UAnkleEveMean = mean(Pool.RAnklePeakEve, 'omitnan'); IAnkleEveMean = mean(Pool.LAnklePeakEve, 'omitnan');
        UAnkleFrontROMMean = mean(Pool.RAnkleFrontROM, 'omitnan'); IAnkleFrontROMMean = mean(Pool.LAnkleFrontROM, 'omitnan');
        UHipExtStanceMean = mean(Pool.RHipPeakExtStance,'omitnan'); IHipExtStanceMean = mean(Pool.LHipPeakExtStance,'omitnan');
        UHipAddStanceMean = mean(Pool.RHipPeakAddStance,'omitnan'); IHipAddStanceMean = mean(Pool.LHipPeakAddStance,'omitnan');
        UHipAbdStanceMean = mean(Pool.RHipPeakAbdStance,'omitnan'); IHipAbdStanceMean = mean(Pool.LHipPeakAbdStance,'omitnan');
        UKneeAddStanceMean = mean(Pool.RKneePeakAddStance,'omitnan'); IKneeAddStanceMean = mean(Pool.LKneePeakAddStance,'omitnan');
        UKneeAbdStanceMean = mean(Pool.RKneePeakAbdStance,'omitnan'); IKneeAbdStanceMean = mean(Pool.LKneePeakAbdStance,'omitnan');
    end

    asym = @(u,i) (100 * (u - i) ./ (u + i));

    SummaryRow = table({Subj}, UNcycles, INcycles, ...
        GaitSpeed, Cadence, ...
        UStrideLenMean, IStrideLenMean, asym(UStrideLenMean, IStrideLenMean), ...
        UStrideTimeMean, IStrideTimeMean, asym(UStrideTimeMean, IStrideTimeMean), ...
        UStepLenMean, IStepLenMean, asym(UStepLenMean, IStepLenMean), ...
        UStepTimeMean, IStepTimeMean, asym(UStepTimeMean, IStepTimeMean), ...
        UDoubleSupportPctMean, IDoubleSupportPctMean, asym(UDoubleSupportPctMean, IDoubleSupportPctMean), ...
        UStancePctMean, IStancePctMean, asym(UStancePctMean, IStancePctMean), ...
        UHipsFlexMean, IHipsFlexMean, asym(UHipsFlexMean, IHipsFlexMean), ...
        UHipsExtMean, IHipsExtMean, asym(UHipsExtMean, IHipsExtMean), ...
        UHipExtStanceMean, IHipExtStanceMean, asym(UHipExtStanceMean, IHipExtStanceMean), ...
        UHipsSagROMMean, IHipsSagROMMean, asym(UHipsSagROMMean, IHipsSagROMMean), ...
        UHipsAbdMean, IHipsAbdMean, asym(UHipsAbdMean, IHipsAbdMean), ...
        UHipsAddMean, IHipsAddMean, asym(UHipsAddMean, IHipsAddMean), ...
        UHipAbdStanceMean, IHipAbdStanceMean, asym(UHipAbdStanceMean, IHipAbdStanceMean), ...
        UHipAddStanceMean, IHipAddStanceMean, asym(UHipAddStanceMean, IHipAddStanceMean), ...
        UHipsFrontROMMean, IHipsFrontROMMean, asym(UHipsFrontROMMean, IHipsFrontROMMean), ...
        UKneeFlexStanceMean, IKneeFlexStanceMean, asym(UKneeFlexStanceMean, IKneeFlexStanceMean), ...
        UKneeFlexSwingMean, IKneeFlexSwingMean, asym(UKneeFlexSwingMean, IKneeFlexSwingMean), ...
        UKneeExtMean, IKneeExtMean, asym(UKneeExtMean, IKneeExtMean), ...
        UKneeSagROMMean, IKneeSagROMMean, asym(UKneeSagROMMean, IKneeSagROMMean), ...
        UKneeAbdMean, IKneeAbdMean, asym(UKneeAbdMean, IKneeAbdMean), ...
        UKneeAddMean, IKneeAddMean, asym(UKneeAddMean, IKneeAddMean), ...
        UKneeAbdStanceMean, IKneeAbdStanceMean, asym(UKneeAbdStanceMean, IKneeAbdStanceMean), ...
        UKneeAddStanceMean, IKneeAddStanceMean, asym(UKneeAddStanceMean, IKneeAddStanceMean), ...
        UKneeFrontROMMean, IKneeFrontROMMean, asym(UKneeFrontROMMean, IKneeFrontROMMean), ...
        UAnkleDorsiMean, IAnkleDorsiMean, asym(UAnkleDorsiMean, IAnkleDorsiMean), ...
        UAnklePlantarMean, IAnklePlantarMean, asym(UAnklePlantarMean, IAnklePlantarMean), ...
        UAnkleSagROMMean, IAnkleSagROMMean, asym(UAnkleSagROMMean, IAnkleSagROMMean), ...
        UAnkleInvMean, IAnkleInvMean, asym(UAnkleInvMean, IAnkleInvMean), ...
        UAnkleEveMean, IAnkleEveMean, asym(UAnkleEveMean, IAnkleEveMean), ...
        UAnkleFrontROMMean, IAnkleFrontROMMean, asym(UAnkleFrontROMMean, IAnkleFrontROMMean), ...
        mean(Pool.TrunkPeakFlex, 'omitnan'), mean(Pool.TrunkPeakSway, 'omitnan'), ...
        PhiMean, PhiAbs, P_PhiAbs, PhiCV, PCI, ...
        'VariableNames', {'Participant','nCycles_Uninvolved','nCycles_Involved', ...
        'GaitSpeed','Cadence', ...
        'StrideLength_Uninvolved','StrideLength_Involved','StrideLength_Asym', ...
        'StrideTime_Uninvolved','StrideTime_Involved','StrideTime_Asym', ...
        'StepLength_Uninvolved','StepLength_Involved','StepLength_Asym', ...
        'StepTime_Uninvolved','StepTime_Involved','StepTime_Asym', ...
        'DoubleSupportPct_Uninvolved','DoubleSupportPct_Involved','DoubleSupportPct_Asym', ...
        'StancePct_Uninvolved','StancePct_Involved','StancePct_Asym', ...
        'HipPeakFlex_Uninvolved','HipPeakFlex_Involved','HipPeakFlex_Asym', ...
        'HipPeakExtension_Uninvolved','HipPeakExtension_Involved','HipPeakExtension_Asym', ...
        'HipPeakExtensionStance_Uninvolved','HipPeakExtensionStance_Involved','HipPeakExtensionStance_Asym', ...
        'HipSagittalROM_Uninvolved','HipSagittalROM_Involved','HipSagittalROM_Asym', ...
        'HipPeakAbduction_Uninvolved','HipPeakAbduction_Involved','HipPeakAbduction_Asym', ...
        'HipPeakAdduction_Uninvolved','HipPeakAdduction_Involved','HipPeakAdduction_Asym', ...
        'HipPeakAbductionStance_Uninvolved','HipPeakAbductionStance_Involved','HipPeakAbductionStance_Asym', ...
        'HipPeakAdductionStance_Uninvolved','HipPeakAdductionStance_Involved','HipPeakAdductionStance_Asym', ...
        'HipFrontalROM_Uninvolved','HipFrontalROM_Involved','HipFrontalROM_Asym', ...
        'KneePeakFlexionEarlyStance_Uninvolved','KneePeakFlexionEarlyStance_Involved','KneePeakFlexionEarlyStance_Asym', ...
        'KneePeakFlexionSwing_Uninvolved','KneePeakFlexionSwing_Involved','KneePeakFlexionSwing_Asym', ...
        'KneePeakExtension_Uninvolved','KneePeakExtension_Involved','KneePeakExtension_Asym', ...
        'KneeSagittalROM_Uninvolved','KneeSagittalROM_Involved','KneeSagittalROM_Asym', ...
        'KneePeakAbduction_Uninvolved','KneePeakAbduction_Involved','KneePeakAbduction_Asym', ...
        'KneePeakAdduction_Uninvolved','KneePeakAdduction_Involved','KneePeakAdduction_Asym', ...
        'KneePeakAbductionStance_Uninvolved','KneePeakAbductionStance_Involved','KneePeakAbductionStance_Asym', ...
        'KneePeakAdductionStance_Uninvolved','KneePeakAdductionStance_Involved','KneePeakAdductionStance_Asym', ...
        'KneeFrontalROM_Uninvolved','KneeFrontalROM_Involved','KneeFrontalROM_Asym', ...
        'AnklePeakDorsiflexion_Uninvolved','AnklePeakDorsiflexion_Involved','AnklePeakDorsiflexion_Asym', ...
        'AnklePeakPlantarflexion_Uninvolved','AnklePeakPlantarflexion_Involved','AnklePeakPlantarflexion_Asym', ...
        'AnkleSagittalROM_Uninvolved','AnkleSagittalROM_Involved','AnkleSagittalROM_Asym', ...
        'AnklePeakInversion_Uninvolved','AnklePeakInversion_Involved','AnklePeakInversion_Asym', ...
        'AnklePeakEversion_Uninvolved','AnklePeakEversion_Involved','AnklePeakEversion_Asym', ...
        'AnkleFrontalROM_Uninvolved','AnkleFrontalROM_Involved','AnkleFrontalROM_Asym', ...
        'TrunkPeakFlexion','TrunkPeakSway', ...
        'PhiMean','PhiAbs','P_PhiAbs','PhiCV','PCI'});

    Group_SummaryTable = [Group_SummaryTable; SummaryRow]; 

    %% Export per-subject cycle table
    writetable(SubjCycleTable, fullfile(SubjPath, [Subj '_CycleTable.xlsx']));
    writetable(SummaryRow, fullfile(SubjPath, [Subj '_SummaryTable.xlsx']));

    %% PCI plot
    PCIplot = figure;
    plot(Pool.Phi, 'Marker', 'o', 'MarkerSize', 10, 'LineStyle', 'none', 'MarkerEdgeColor', 'b');
    ylim([140 220]);
    set(gca, "FontSize", 12)
    xlabel('Stride','FontSize',16);
    ylabel('Stepping Phase (degrees)','FontSize',16);
    title([Subj ' Phase Coordination Index'], 'FontSize', 18, 'Interpreter', 'none');
    hold on
    Xline = refline([0 180]);
    Xline.Color = 'r';
    Xline.LineWidth = 2;
    text(0.03, 0.05, ['PCI = ' num2str(PCI)], 'Units','normalized','FontSize',18,'FontWeight','bold');
    savefig(PCIplot, fullfile(SubjPath, [Subj, '_PCI_Figure.fig']));
    print(PCIplot, fullfile(SubjPath, [Subj, '_PCI_Figure']), '-dtiff','-r600');
    close(PCIplot)

    %% Average joint kinematic profile plot (Hip/Knee/Ankle, sagittal & frontal)
    gcQuery = linspace(0, 100, 101);

    RHipSagMean    = mean(Pool.RHipSag,2);    LHipSagMean    = mean(Pool.LHipSag,2);
    RHipFrontMean  = mean(Pool.RHipFront,2);  LHipFrontMean  = mean(Pool.LHipFront,2);
    RKneeSagMean   = mean(Pool.RKneeSag,2);   LKneeSagMean   = mean(Pool.LKneeSag,2);
    RKneeFrontMean = mean(Pool.RKneeFront,2); LKneeFrontMean = mean(Pool.LKneeFront,2);
    RAnkleSagMean  = mean(Pool.RAnkleSag,2);  LAnkleSagMean  = mean(Pool.LAnkleSag,2);
    RAnkleFrontMean= mean(Pool.RAnkleFront,2);LAnkleFrontMean= mean(Pool.LAnkleFront,2);

    if strcmp(uninvolvedSideCode, 'L')
        UHipSagMean = LHipSagMean; IHipSagMean = RHipSagMean;
        UHipFrontMean = LHipFrontMean; IHipFrontMean = RHipFrontMean;
        UKneeSagMean = LKneeSagMean; IKneeSagMean = RKneeSagMean;
        UKneeFrontMean = LKneeFrontMean; IKneeFrontMean = RKneeFrontMean;
        UAnkleSagMean = LAnkleSagMean; IAnkleSagMean = RAnkleSagMean;
        UAnkleFrontMean = LAnkleFrontMean; IAnkleFrontMean = RAnkleFrontMean;
    else
        UHipSagMean = RHipSagMean; IHipSagMean = LHipSagMean;
        UHipFrontMean = RHipFrontMean; IHipFrontMean = LHipFrontMean;
        UKneeSagMean = RKneeSagMean; IKneeSagMean = LKneeSagMean;
        UKneeFrontMean = RKneeFrontMean; IKneeFrontMean = LKneeFrontMean;
        UAnkleSagMean = RAnkleSagMean; IAnkleSagMean = LAnkleSagMean;
        UAnkleFrontMean = RAnkleFrontMean; IAnkleFrontMean = LAnkleFrontMean;
    end

    Profile = struct();

    Profile.Participant = Subj;
    Profile.GaitCycle = gcQuery(:);

    Profile.RHipSag = RHipSagMean;
    Profile.LHipSag = LHipSagMean;
    Profile.UHipSag = UHipSagMean;
    Profile.IHipSag = IHipSagMean;

    Profile.RHipFront = RHipFrontMean;
    Profile.LHipFront = LHipFrontMean;
    Profile.UHipFront = UHipFrontMean;
    Profile.IHipFront = IHipFrontMean;

    Profile.RKneeSag = RKneeSagMean;
    Profile.LKneeSag = LKneeSagMean;
    Profile.UKneeSag = UKneeSagMean;
    Profile.IKneeSag = IKneeSagMean;

    Profile.RKneeFront = RKneeFrontMean;
    Profile.LKneeFront = LKneeFrontMean;
    Profile.UKneeFront = UKneeFrontMean;
    Profile.IKneeFront = IKneeFrontMean;

    Profile.RAnkleSag = RAnkleSagMean;
    Profile.LAnkleSag = LAnkleSagMean;
    Profile.UAnkleSag = UAnkleSagMean;
    Profile.IAnkleSag = IAnkleSagMean;

    Profile.RAnkleFront = RAnkleFrontMean;
    Profile.LAnkleFront = LAnkleFrontMean;
    Profile.UAnkleFront = UAnkleFrontMean;
    Profile.IAnkleFront = IAnkleFrontMean;

    % Row 1 = Hip, Row 2 = Knee, Row 3 = Ankle; Col 1 = Sagittal, Col 2 = Frontal.
    plotSpecs = {
        RHipSagMean,     LHipSagMean,     'Hip Sagittal',     'Flexion',       'Extension';
        RHipFrontMean,   LHipFrontMean,   'Hip Frontal',      'Adduction',     'Abduction';
        RKneeSagMean,    LKneeSagMean,    'Knee Sagittal',    'Flexion',     'Extension';
        RKneeFrontMean,  LKneeFrontMean,  'Knee Frontal',     'Adduction',   'Abduction';
        RAnkleSagMean,   LAnkleSagMean,   'Ankle Sagittal',   'Dorsiflexion',  'Plantarflexion';
        RAnkleFrontMean, LAnkleFrontMean, 'Ankle Frontal',    'Inversion',        'Eversion'
    };

    ProfilePlot = figure('Position',[100 100 1000 900]);
    for p = 1:6
        subplot(3,2,p)
        Rcurve = plotSpecs{p,1}; Lcurve = plotSpecs{p,2};

        % Use the same uninvolved/involved remapping as the tables so the
        % profile plots match the side labels reported in the outputs.
        if strcmp(uninvolvedSideCode, 'L')
            Ucurve = Lcurve; Icurve = Rcurve;
        else
            Ucurve = Rcurve; Icurve = Lcurve;
        end

        plot(gcQuery, Ucurve, 'b-', 'LineWidth', 1.5); hold on
        plot(gcQuery, Icurve, 'r-', 'LineWidth', 1.5);

        [UmaxV, UmaxI] = max(Ucurve); [UminV, UminI] = min(Ucurve);
        [ImaxV, ImaxI] = max(Icurve); [IminV, IminI] = min(Icurve);

        plot(gcQuery(UmaxI), UmaxV, 'bo', 'MarkerFaceColor','b', 'MarkerSize',6);
        plot(gcQuery(UminI), UminV, 'bs', 'MarkerFaceColor','b', 'MarkerSize',6);
        plot(gcQuery(ImaxI), ImaxV, 'ro', 'MarkerFaceColor','r', 'MarkerSize',6);
        plot(gcQuery(IminI), IminV, 'rs', 'MarkerFaceColor','r', 'MarkerSize',6);

        text(gcQuery(UmaxI), UmaxV, sprintf('  %.1f%s', UmaxV, char(176)), 'Color','b', 'FontSize',8);
        text(gcQuery(UminI), UminV, sprintf('  %.1f%s', UminV, char(176)), 'Color','b', 'FontSize',8);
        text(gcQuery(ImaxI), ImaxV, sprintf('  %.1f%s', ImaxV, char(176)), 'Color','r', 'FontSize',8);
        text(gcQuery(IminI), IminV, sprintf('  %.1f%s', IminV, char(176)), 'Color','r', 'FontSize',8);

        title(sprintf('%s (+%s / -%s)', plotSpecs{p,3}, plotSpecs{p,4}, plotSpecs{p,5}), ...
            'FontSize', 10, 'Interpreter', 'none')
        xlabel('% Gait Cycle')
        ylabel('Angle (deg)')
        xlim([0 100])
        if p == 1
            legend({'Uninvolved','Involved'}, 'Location','north')
        end
        hold off
    end
    sgtitle([Subj ' Average Joint Kinematics'], 'Interpreter', 'none')

    save(fullfile(SubjPath,[Subj '_AverageProfiles.mat']), 'Profile');
    GroupProfiles.(Subj) = Profile;
    savefig(ProfilePlot, fullfile(SubjPath, [Subj '_KinematicProfile.fig']));
    try
        exportgraphics(ProfilePlot, fullfile(SubjPath, [Subj '_KinematicProfile.tiff']), 'Resolution', 600);
    catch
        warning('exportgraphics failed for %s; saving a PNG instead.', Subj);
        exportgraphics(ProfilePlot, fullfile(SubjPath, [Subj '_KinematicProfile.png']), 'Resolution', 600);
    end
    close(ProfilePlot)
end

%% Export group data
writetable(Group_SummaryTable, fullfile(RootDir,'Group_SummaryTable.xlsx'));
save(fullfile(RootDir,'Group_AverageProfiles.mat'), 'GroupProfiles');