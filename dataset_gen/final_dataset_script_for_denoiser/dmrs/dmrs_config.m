function dmrsCfg = dmrs_config(channelType, varargin)
%DMRS_CONFIG Configurable DMRS pattern for 6G study.
%
%   dmrsCfg = DMRS_CONFIG('PDSCH')  — NR Rel-15 Type 1 baseline
%   dmrsCfg = DMRS_CONFIG('PDSCH', 'Pattern','sparse_half_fd')
%   dmrsCfg = DMRS_CONFIG('PDCCH')  — NR PDCCH DMRS baseline
%   dmrsCfg = DMRS_CONFIG('PUSCH', 'Waveform','DFT-s-OFDM')
%
%   This module is the central innovation point. It generates DMRS configs
%   for both non-AI experiments and AI dataset generation.
%
%   Supported patterns:
%     'nr_baseline'       — NR Rel-15 Type 1 (PDSCH/PUSCH) or NR PDCCH DMRS
%     'sparse_half_fd'    — Half frequency density (Samsung Pattern 3 equivalent)
%     'sparse_quarter_fd' — Quarter frequency density
%     'sparse_td'         — Reduced time-domain DMRS symbols
%     'sparse_fd_td'      — Sparse in both freq and time
%     'custom'            — Fully custom pattern via additional parameters
%
%   For PDCCH:
%     'pdcch_nr_baseline' — 3 DMRS per REG (RE#1, RE#5, RE#9), single port
%     'pdcch_sparse'      — Reduced DMRS density per REG
%     'pdcch_2port_sfbc'  — 2-port SFBC DMRS (Xiaomi proposal)
%
%   Source: RAN1#124 FL Summaries + Samsung R1-2509516 Annex C

    p = inputParser;
    addRequired(p, 'channelType', @(x) ismember(x, {'PDSCH','PUSCH','PDCCH','PUCCH'}));
    addParameter(p, 'Pattern', 'nr_baseline');
    addParameter(p, 'NumDMRSPorts', 1);
    addParameter(p, 'MaxOrthogonalPorts', 12);  % NR Type 1 max; 6G: up to 96
    addParameter(p, 'DMRSConfigType', 1);        % NR: 1 or 2; 6G: unified (1)
    addParameter(p, 'DMRSLength', 1);             % 1=single-symbol, 2=double-symbol
    addParameter(p, 'DMRSAdditionalPosition', 1); % 0-3
    addParameter(p, 'DMRSTypeAPosition', 2);      % 2 or 3
    addParameter(p, 'NumCDMGroupsWithoutData', 2);
    addParameter(p, 'DMRSPortSet', 0);
    addParameter(p, 'NIDNSCID', []);
    addParameter(p, 'NSCID', 0);
    addParameter(p, 'CustomSymbolSet', []);
    addParameter(p, 'Waveform', 'CP-OFDM');       % CP-OFDM or DFT-s-OFDM (PUSCH)
    addParameter(p, 'EnablePTRS', false);
    addParameter(p, 'PTRSTimeDensity', 1);
    addParameter(p, 'PTRSFreqDensity', 2);
    % 6G-specific extensions
    addParameter(p, 'FDDensityReduction', 1.0);   % 1.0=full, 0.5=half, 0.25=quarter
    addParameter(p, 'TDDensityReduction', 1.0);   % 1.0=full, 0.5=half symbols
    addParameter(p, 'PowerBoosting', true);        % DMRS power boosting
    addParameter(p, 'PowerBoostdB', 0);            % dB above data
    % PDCCH specific
    addParameter(p, 'PDCCHDMRSPerREG', 3);        % NR: 3 (RE#1,#5,#9 out of 12)
    addParameter(p, 'PDCCHTxDiversity', 'precoder_cycling'); % or 'SFBC'
    
    parse(p, channelType, varargin{:});
    r = p.Results;
    
    %% Build config based on channel type
    switch upper(channelType)
        case 'PDSCH'
            dmrsCfg = buildPDSCH_DMRS(r);
        case 'PUSCH'
            dmrsCfg = buildPUSCH_DMRS(r);
        case 'PDCCH'
            dmrsCfg = buildPDCCH_DMRS(r);
        case 'PUCCH'
            dmrsCfg = buildPUCCH_DMRS(r);
    end
    
    % Attach metadata for dataset generation
    dmrsCfg.ChannelType = channelType;
    dmrsCfg.PatternName = r.Pattern;
    dmrsCfg.FDDensityReduction = r.FDDensityReduction;
    dmrsCfg.TDDensityReduction = r.TDDensityReduction;
    dmrsCfg.PowerBoosting = r.PowerBoosting;
    dmrsCfg.PowerBoostdB = r.PowerBoostdB;
end

%% ========== PDSCH DMRS Configuration ==========
function cfg = buildPDSCH_DMRS(r)
    cfg = struct();
    
    % Map pattern name to concrete parameters
    switch r.Pattern
        case 'nr_baseline'
            % NR Rel-15 Type 1, single-symbol, 1 additional position
            % This is Samsung's "Pattern 1" benchmark
            cfg.DMRSConfigurationType = 1;
            cfg.DMRSLength = 1;
            cfg.DMRSAdditionalPosition = 1;
            cfg.DMRSTypeAPosition = 2;
            cfg.NumCDMGroupsWithoutData = 2;
            cfg.DMRSPortSet = r.DMRSPortSet;
            cfg.NIDNSCID = r.NIDNSCID;
            cfg.NSCID = 0;
            cfg.CustomSymbolSet = [];
            
        case 'nr_baseline_double'
            % NR Rel-15 Type 1, double-symbol
            cfg.DMRSConfigurationType = 1;
            cfg.DMRSLength = 2;
            cfg.DMRSAdditionalPosition = 1;
            cfg.DMRSTypeAPosition = 2;
            cfg.NumCDMGroupsWithoutData = 2;
            cfg.DMRSPortSet = r.DMRSPortSet;
            cfg.NIDNSCID = r.NIDNSCID;
            cfg.NSCID = 0;
            cfg.CustomSymbolSet = [];
            
        case 'sparse_fd'
            % Reduced frequency density: Type 2 instead of Type 1
            % Type 2: 4 DMRS subcarriers per PRB (SC 0,1,6,7) vs Type 1: 6 (SC 0,2,4,6,8,10)
            % Keeps 2 time-domain symbols (same as baseline)
            % DMRS REs per PRB: 4 SC × 2 symbols = 8 (vs baseline 12)
            cfg.DMRSConfigurationType = 2;
            cfg.DMRSLength = 1;
            cfg.DMRSAdditionalPosition = 1;
            cfg.DMRSTypeAPosition = 2;
            cfg.NumCDMGroupsWithoutData = 1;
            cfg.DMRSPortSet = r.DMRSPortSet;
            cfg.NIDNSCID = r.NIDNSCID;
            cfg.NSCID = 0;
            cfg.CustomSymbolSet = [];
            
        case 'sparse_td'
            % Reduced time density: 1 DMRS symbol instead of 2
            % Keeps Type 1 (6 SC per PRB, same frequency density as baseline)
            % DMRS REs per PRB: 6 SC × 1 symbol = 6 (vs baseline 12)
            cfg.DMRSConfigurationType = 1;
            cfg.DMRSLength = 1;
            cfg.DMRSAdditionalPosition = 0;
            cfg.DMRSTypeAPosition = 2;
            cfg.NumCDMGroupsWithoutData = 2;
            cfg.DMRSPortSet = r.DMRSPortSet;
            cfg.NIDNSCID = r.NIDNSCID;
            cfg.NSCID = 0;
            cfg.CustomSymbolSet = [];
            
        case 'sparse_fd_td'
            % Reduced in BOTH frequency and time
            % Type 2 (4 SC per PRB) + 1 DMRS symbol
            % DMRS REs per PRB: 4 SC × 1 symbol = 4 (vs baseline 12)
            cfg.DMRSConfigurationType = 2;
            cfg.DMRSLength = 1;
            cfg.DMRSAdditionalPosition = 0;
            cfg.DMRSTypeAPosition = 2;
            cfg.NumCDMGroupsWithoutData = 1;
            cfg.DMRSPortSet = r.DMRSPortSet;
            cfg.NIDNSCID = r.NIDNSCID;
            cfg.NSCID = 0;
            cfg.CustomSymbolSet = [];
            
        case 'custom'
            % Pass through all user parameters
            cfg.DMRSConfigurationType = r.DMRSConfigType;
            cfg.DMRSLength = r.DMRSLength;
            cfg.DMRSAdditionalPosition = r.DMRSAdditionalPosition;
            cfg.DMRSTypeAPosition = r.DMRSTypeAPosition;
            cfg.NumCDMGroupsWithoutData = r.NumCDMGroupsWithoutData;
            cfg.DMRSPortSet = r.DMRSPortSet;
            cfg.NIDNSCID = r.NIDNSCID;
            cfg.NSCID = r.NSCID;
            cfg.CustomSymbolSet = r.CustomSymbolSet;
            
        otherwise
            error('Unknown PDSCH DMRS pattern: %s', r.Pattern);
    end
    
    % PT-RS config
    cfg.EnablePTRS = r.EnablePTRS;
    cfg.PTRSTimeDensity = r.PTRSTimeDensity;
    cfg.PTRSFreqDensity = r.PTRSFreqDensity;
    
    % Calculate overhead ratio for reporting
    cfg.OverheadInfo = calcPDSCH_DMRSOverhead(cfg);
end

%% ========== PUSCH DMRS Configuration ==========
function cfg = buildPUSCH_DMRS(r)
    % PUSCH DMRS largely mirrors PDSCH, with additions for DFT-s-OFDM
    cfg = buildPDSCH_DMRS(r);  % Start from PDSCH config
    cfg.Waveform = r.Waveform;
    cfg.TransformPrecoding = strcmp(r.Waveform, 'DFT-s-OFDM');
    
    % For DFT-s-OFDM, DMRS sequence design differs (low PAPR ZC-based)
    if cfg.TransformPrecoding
        cfg.GroupHopping = 'neither';  % Can be 'neither','enable','disable'
        cfg.SequenceHopping = 'neither';
    end
end

%% ========== PDCCH DMRS Configuration ==========
function cfg = buildPDCCH_DMRS(r)
    % PDCCH DMRS is structurally different from PDSCH/PUSCH
    % NR baseline: single port, 3 DMRS per REG at RE#1, RE#5, RE#9
    cfg = struct();
    
    switch r.Pattern
        case {'nr_baseline', 'pdcch_nr_baseline'}
            cfg.NumPorts = 1;
            cfg.DMRSPerREG = 3;           % 3 out of 12 REs per REG
            cfg.DMRSREPositions = [1 5 9]; % 0-indexed within REG
            cfg.DMRSDensity = 3/12;        % 25%
            cfg.TxDiversity = 'precoder_cycling';
            cfg.ScramblingType = 'cell_specific';  % NR: cell ID based
            
        case 'pdcch_sparse'
            % Reduced density: 2 DMRS per REG (study item from ZTE, Ofinno)
            cfg.NumPorts = 1;
            cfg.DMRSPerREG = 2;
            cfg.DMRSREPositions = [1 7];   % Example sparse positions
            cfg.DMRSDensity = 2/12;
            cfg.TxDiversity = 'precoder_cycling';
            cfg.ScramblingType = 'cell_specific';
            
        case 'pdcch_2port_sfbc'
            % 2-port SFBC (Xiaomi R1-2600432 results)
            cfg.NumPorts = 2;
            cfg.DMRSPerREG = 3;
            cfg.DMRSREPositions = [1 5 9];
            cfg.DMRSDensity = 3/12;        % Same overhead, 2 ports
            cfg.TxDiversity = 'SFBC';
            cfg.ScramblingType = 'cell_specific';
            
        case 'custom'
            cfg.NumPorts = r.NumDMRSPorts;
            cfg.DMRSPerREG = r.PDCCHDMRSPerREG;
            cfg.DMRSREPositions = [];  % To be filled
            cfg.DMRSDensity = r.PDCCHDMRSPerREG / 12;
            cfg.TxDiversity = r.PDCCHTxDiversity;
            cfg.ScramblingType = 'cell_specific';
    end
    
    % PDCCH specific: CORESET config
    cfg.AggregationLevels = [1 2 4 8 16];
    cfg.REGsPerCCE = 6;
    cfg.REsPerREG = 12;
end

%% ========== PUCCH DMRS Configuration ==========
function cfg = buildPUCCH_DMRS(r)
    % PUCCH DMRS — placeholder, follows PUSCH DMRS design direction
    % Per UL FL summary: "If needed, designs for PUCCH DMRS"
    cfg = struct();
    cfg.NumPorts = 1;
    cfg.DMRSConfigurationType = 1;
    cfg.Note = 'PUCCH DMRS design follows PUSCH. Detailed config TBD per RAN1 progress.';
end

%% ========== Overhead Calculation ==========
function info = calcPDSCH_DMRSOverhead(cfg)
    % Calculate DMRS overhead as fraction of total REs in a slot
    % For NR Type 1: 6 DMRS REs per PRB per symbol per CDM group
    % With NumCDMGroupsWithoutData CDM groups
    
    REsPerPRBPerSymbol = 12;
    symbolsPerSlot = 14;  % Normal CP
    
    % DMRS REs per PRB per DMRS symbol
    if cfg.DMRSConfigurationType == 1
        dmrsREsPerPRB = 6;  % Type 1: every other subcarrier
    else
        dmrsREsPerPRB = 4;  % Type 2: 2 groups of 2 consecutive
    end
    
    % Number of DMRS symbols
    numDMRSSymbols = 1 + cfg.DMRSAdditionalPosition;
    if cfg.DMRSLength == 2
        numDMRSSymbols = numDMRSSymbols * 2;
    end
    
    % Overhead
    dmrsREs = dmrsREsPerPRB * numDMRSSymbols;
    totalREs = REsPerPRBPerSymbol * symbolsPerSlot;
    
    info.DMRSREsPerPRB = dmrsREs;
    info.TotalREsPerPRB = totalREs;
    info.OverheadRatio = dmrsREs / totalREs;
    info.NumDMRSSymbols = numDMRSSymbols;
    info.Description = sprintf('%.1f%% DMRS overhead (%d/%d REs per PRB)', ...
        info.OverheadRatio*100, dmrsREs, totalREs);
end
