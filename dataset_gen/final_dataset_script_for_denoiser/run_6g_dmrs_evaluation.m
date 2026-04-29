%% run_6g_dmrs_evaluation.m
% Master script for 6G DMRS link-level evaluation.
%
% This script runs the PDSCH LLS across RAN1#124 agreed EVM parameters
% and generates both non-AI results and AI training datasets.
%
% Usage:
%   1. Set your scenario in the CONFIGURATION section below
%   2. Run this script
%   3. Results saved to ./results/ and datasets to ./dataset/
%
% Prerequisites:
%   - MATLAB R2024a+ with 5G Toolbox
%   - 6G Exploration Library add-on (free from MATLAB Add-On Explorer)
%   - Parallel Computing Toolbox (optional, for speed)

clearvars; close all; clc;
addpath(genpath(pwd));  % Add all subdirectories

%% ===== CONFIGURATION =====
% Choose what to run. Uncomment/modify as needed.

% --- Scenario Selection ---
% Options: '4GHz_Uma_baseline', '0.7GHz_suburban', '7GHz_dense', 'custom'
scenario = '4GHz_Uma_baseline';

% --- DMRS Patterns to Compare ---
% Each pattern will be evaluated across all SNR points
dmrsPatterns = {
    'nr_baseline'       % NR Rel-15 Type 1 (benchmark)
    'sparse_fd'         % Reduced frequency density (Type 2)
    'sparse_td'         % Sparse in time
    'sparse_fd_td'      % Sparse in both
};

% --- AI Dataset Generation ---
generateDataset = true;     % Set true to save data for PyTorch training
maxSamplesPerSNR = 500;     % Samples per SNR point per pattern

% --- Quick vs Full Simulation ---
quickMode = true;  % true = 2 frames (for testing), false = 100 frames

%% ===== BUILD CONFIGURATIONS =====
switch scenario
    case '4GHz_Uma_baseline'
        % Most common 6G scenario: 4 GHz TDD, 30 kHz SCS, CDL-C
        simCfg = evm_pdsch_lls(...
            'CarrierFreq', 4e9, ...
            'SubcarrierSpacing', 30, ...
            'BandwidthMHz', 20, ...
            'DelayProfile', 'CDL-C', ...
            'DelaySpread', 100e-9, ...
            'UESpeed_kmh', 30, ...
            'NTxAnts', 4, ...
            'NRxAnts', 2, ...
            'TxArrayConfig', [8 2 2 1 1 1 2], ...
            'TxAntSpacing', [0.5 0.8], ...
            'Modulation', '16QAM', ...
            'NumLayers', 1, ...
            'SNRdB', -5:2:25 ...
        );
        
    case '0.7GHz_suburban'
        simCfg = evm_pdsch_lls(...
            'CarrierFreq', 0.7e9, ...
            'SubcarrierSpacing', 15, ...
            'BandwidthMHz', 20, ...
            'DelayProfile', 'CDL-A', ...
            'DelaySpread', 300e-9, ...
            'UESpeed_kmh', 40, ...
            'NTxAnts', 4, ...
            'NRxAnts', 2, ...
            'TxArrayConfig', [8 2 2 1 1 1 2], ...
            'TxAntSpacing', [0.5 0.5], ...
            'Modulation', 'QPSK', ...
            'NumLayers', 1, ...
            'SNRdB', -10:2:20 ...
        );
        
    case '7GHz_dense'
        % 6G-specific: 7 GHz with massive arrays
        simCfg = evm_pdsch_lls(...
            'CarrierFreq', 7e9, ...
            'SubcarrierSpacing', 30, ...
            'BandwidthMHz', 100, ...
            'DelayProfile', 'CDL-C', ...
            'DelaySpread', 100e-9, ...
            'UESpeed_kmh', 3, ...
            'NTxAnts', 128, ...
            'NRxAnts', 4, ...
            'TxArrayConfig', [24 16 2 1 1 4 16], ...
            'TxAntSpacing', [0.5 0.8], ...
            'Modulation', '64QAM', ...
            'NumLayers', 2, ...
            'SNRdB', -5:2:30 ...
        );
        
    otherwise
        error('Unknown scenario: %s', scenario);
end

% Override frame count for quick mode
if quickMode
    simCfg.NFrames = 2;
else
    simCfg.NFrames = 100;
end

%% ===== RUN SIMULATIONS =====
fprintf('=== 6G DMRS Link-Level Evaluation ===\n');
fprintf('Scenario: %s\n', scenario);
fprintf('Carrier: %.1f GHz, SCS: %d kHz, BW: %d MHz\n', ...
    simCfg.CarrierFreq/1e9, simCfg.SubcarrierSpacing, simCfg.BandwidthMHz);
fprintf('Channel: %s, DS: %d ns, Speed: %d km/h\n', ...
    simCfg.DelayProfile, simCfg.DelaySpread*1e9, simCfg.UESpeed_kmh);
fprintf('Antennas: %dx%d\n', simCfg.NTxAnts, simCfg.NRxAnts);
fprintf('Frames: %d\n\n', simCfg.NFrames);

allResults = struct();

for p = 1:numel(dmrsPatterns)
    patternName = dmrsPatterns{p};
    fprintf('\n--- Pattern %d/%d: %s ---\n', p, numel(dmrsPatterns), patternName);
    
    % Build DMRS config
    dmrsCfg = dmrs_config('PDSCH', 'Pattern', patternName);
    fprintf('DMRS: %s\n', dmrsCfg.OverheadInfo.Description);
    
    % Run simulation
    results = run_pdsch_lls(simCfg, dmrsCfg, ...
        'GenerateDataset', generateDataset, ...
        'DatasetPath', fullfile('./dataset', scenario), ...
        'MaxSamplesPerSNR', maxSamplesPerSNR, ...
        'Verbose', true);
    
    % Store
    allResults.(patternName) = results;
end

%% ===== PLOT RESULTS =====
fprintf('\n\n=== Results Summary ===\n');

figure('Position', [100 100 1200 400]);

% BLER vs SNR
subplot(1,3,1);
hold on; grid on;
legendEntries = {};
for p = 1:numel(dmrsPatterns)
    r = allResults.(dmrsPatterns{p});
    semilogy(r.SNRdB, max(r.BLER, 1e-4), '-o', 'LineWidth', 1.5, 'MarkerSize', 4);
    legendEntries{end+1} = strrep(dmrsPatterns{p}, '_', ' '); %#ok<SAGROW>
end
xlabel('SNR (dB)'); ylabel('BLER');
title('BLER vs SNR');
legend(legendEntries, 'Location', 'southwest');
ylim([1e-4 1]);

% Throughput vs SNR
subplot(1,3,2);
hold on; grid on;
for p = 1:numel(dmrsPatterns)
    r = allResults.(dmrsPatterns{p});
    plot(r.SNRdB, r.Throughput, '-o', 'LineWidth', 1.5, 'MarkerSize', 4);
end
xlabel('SNR (dB)'); ylabel('Throughput (%)');
title('Throughput vs SNR');
legend(legendEntries, 'Location', 'southeast');

% MSE vs SNR
subplot(1,3,3);
hold on; grid on;
for p = 1:numel(dmrsPatterns)
    r = allResults.(dmrsPatterns{p});
    semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), '-o', 'LineWidth', 1.5, 'MarkerSize', 4);
end
xlabel('SNR (dB)'); ylabel('Channel Estimation MSE');
title('CE MSE vs SNR');
legend(legendEntries, 'Location', 'northeast');

sgtitle(sprintf('6G PDSCH DMRS Evaluation — %s', scenario), 'FontWeight', 'bold');

% Save results
resultsDir = './results';
if ~exist(resultsDir, 'dir'); mkdir(resultsDir); end
resultFile = fullfile(resultsDir, [scenario '_' datestr(now,'yyyymmdd_HHMMSS') '.mat']);
save(resultFile, 'allResults', 'simCfg', 'dmrsPatterns', 'scenario');
fprintf('\nResults saved to: %s\n', resultFile);

% Save figure
figFile = fullfile(resultsDir, [scenario '_' datestr(now,'yyyymmdd_HHMMSS') '.png']);
saveas(gcf, figFile);
fprintf('Figure saved to: %s\n', figFile);
