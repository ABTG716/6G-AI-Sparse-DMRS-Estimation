function antCfg = antenna_configs(freqBand, configName)
%ANTENNA_CONFIGS All agreed antenna configurations from RAN1#124 Chair Notes.
%
%   antCfg = ANTENNA_CONFIGS('4GHz', 'Outdoor_Combo_1')
%   antCfg = ANTENNA_CONFIGS('0.7GHz', 'Baseline')
%
%   Returns struct with fields:
%     NTxAnts    - Number of TXRUs
%     NumAEs     - Number of antenna elements
%     ArrayConfig - [M N P Mg Ng Mp Np]
%     AntSpacing  - [dH dV] in wavelengths
%     Label       - Human-readable label
%
%   Source: Chair_notes_RAN1_124_-_eom.docx, BS antenna configuration table

    configs = struct();
    
    %% ===== Around 0.7 GHz (FDD) =====
    configs.f07.Baseline = makeConfig(4, 32, [8 2 2 1 1 1 2], [0.5 0.5], ...
        '0.7GHz Baseline: 4 TXRUs, 32 AEs');
    
    %% ===== Around 2 GHz (FDD) =====
    configs.f2.Outdoor_Combo_1 = makeConfig(4, 32, [8 2 2 1 1 1 2], [0.5 0.5], ...
        '2GHz Outdoor Combo 1: 4 TXRUs, 32 AEs');
    configs.f2.Outdoor_Combo_2_32T = makeConfig(32, 128, [8 8 2 1 1 2 8], [0.5 0.5], ...
        '2GHz: 32 TXRUs, 128 AEs');
    configs.f2.Outdoor_Combo_2_64T = makeConfig(64, 192, [12 8 2 1 1 4 8], [0.5 0.5], ...
        '2GHz Outdoor Combo 2: 64 TXRUs, 192 AEs');
    
    %% ===== Around 4 GHz (TDD) =====
    configs.f4.Outdoor_Combo_0 = makeConfig(4, 32, [8 2 2 1 1 1 2], [0.5 0.8], ...
        '4GHz Outdoor Combo 0: 4 TXRUs, 32 AEs');
    configs.f4.Indoor_Combo_1 = makeConfig(32, 128, [8 8 2 1 1 2 8], [0.5 0.8], ...
        '4GHz Indoor Combo 1: 32 TXRUs, 128 AEs');
    configs.f4.Outdoor_Combo_1 = makeConfig(64, 192, [12 8 2 1 1 4 8], [0.5 0.8], ...
        '4GHz Outdoor Combo 1: 64 TXRUs, 192 AEs');
    
    %% ===== Around 7 GHz (TDD) — FFS but captured =====
    configs.f7.Outdoor_Combo_1 = makeConfig(128, 768, [24 16 2 1 1 4 16], [0.5 0.8], ...
        '7GHz Outdoor Combo 1: 128 TXRUs, 768 AEs');
    configs.f7.Outdoor_Combo_2 = makeConfig(256, 1024, [32 16 2 1 1 8 16], [0.5 0.8], ...
        '7GHz Outdoor Combo 2: 256 TXRUs, 1024 AEs');
    configs.f7.Outdoor_Combo_5 = makeConfig(512, 2048, [64 16 2 1 1 16 16], [0.5 0.5], ...
        '7GHz Outdoor Combo 5: 512 TXRUs, 2048 AEs');
    configs.f7.Outdoor_Combo_3 = makeConfig(256, 1536, [48 16 2 1 1 8 16], [0.5 0.8], ...
        '7GHz Outdoor Combo 3: 256 TXRUs, 1536 AEs');
    configs.f7.Config_128T_2048AE = makeConfig(128, 2048, [64 16 2 1 1 8 8], [0.5 0.5], ...
        '7GHz: 128 TXRUs, 2048 AEs');
    
    %% ===== Around 30 GHz (TDD) =====
    configs.f30.Outdoor_Combo_3 = makeConfig(4, 1024, [16 16 2 2 1 1 1], [0.5 0.5], ...
        '30GHz Outdoor Combo 3: 4 TXRUs, 1024 AEs');
    configs.f30.Outdoor_Combo_1 = makeConfig(16, 2048, [16 8 2 4 2 1 1], [0.5 0.5], ...
        '30GHz Outdoor Combo 1: 16 TXRUs, 2048 AEs');
    
    %% --- Lookup ---
    freqMap = containers.Map(...
        {'0.7GHz','2GHz','4GHz','7GHz','30GHz'}, ...
        {'f07','f2','f4','f7','f30'});
    
    if nargin == 0
        % Return all configs
        antCfg = configs;
        return;
    end
    
    if ~freqMap.isKey(freqBand)
        error('Unknown frequency band: %s. Use 0.7GHz/2GHz/4GHz/7GHz/30GHz', freqBand);
    end
    
    bandConfigs = configs.(freqMap(freqBand));
    
    if nargin < 2
        % Return all configs for this band
        antCfg = bandConfigs;
        return;
    end
    
    if ~isfield(bandConfigs, configName)
        error('Unknown config "%s" for %s. Available: %s', ...
            configName, freqBand, strjoin(fieldnames(bandConfigs), ', '));
    end
    
    antCfg = bandConfigs.(configName);
end

function s = makeConfig(nTXRU, nAE, arrayConfig, spacing, label)
    s.NTxAnts = nTXRU;
    s.NumAEs = nAE;
    s.ArrayConfig = arrayConfig;  % [M N P Mg Ng Mp Np]
    s.AntSpacing = spacing;       % [dH dV]
    s.Label = label;
end
