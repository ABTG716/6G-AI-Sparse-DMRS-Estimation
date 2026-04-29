function sweepResults = sweep_evm_parameters(varargin)
%SWEEP_EVM_PARAMETERS Run systematic sweeps across agreed EVM parameters.
%
%   sweepResults = SWEEP_EVM_PARAMETERS()          — default sweep
%   sweepResults = SWEEP_EVM_PARAMETERS('Sweep','delay_spread')
%   sweepResults = SWEEP_EVM_PARAMETERS('Sweep','ue_speed')
%   sweepResults = SWEEP_EVM_PARAMETERS('Sweep','frequency')
%   sweepResults = SWEEP_EVM_PARAMETERS('Sweep','channel_model')
%   sweepResults = SWEEP_EVM_PARAMETERS('Sweep','dmrs_pattern')
%   sweepResults = SWEEP_EVM_PARAMETERS('Sweep','full')  — all combinations
%
%   Runs across the RAN1#124 agreed parameter ranges and produces
%   comparison plots. Results can be directly used in TDoc figures.

    p = inputParser;
    addParameter(p, 'Sweep', 'dmrs_pattern');
    addParameter(p, 'QuickMode', true);
    addParameter(p, 'GenerateDataset', false);
    addParameter(p, 'SaveResults', true);
    parse(p, varargin{:});
    opts = p.Results;
    
    nFrames = 2;
    if ~opts.QuickMode; nFrames = 50; end
    
    fprintf('=== 6G DMRS Parameter Sweep: %s ===\n\n', opts.Sweep);
    
    switch opts.Sweep
        case 'delay_spread'
            sweepResults = sweepDelaySpread(nFrames, opts);
        case 'ue_speed'
            sweepResults = sweepUESpeed(nFrames, opts);
        case 'frequency'
            sweepResults = sweepFrequency(nFrames, opts);
        case 'channel_model'
            sweepResults = sweepChannelModel(nFrames, opts);
        case 'dmrs_pattern'
            sweepResults = sweepDMRSPattern(nFrames, opts);
        case 'full'
            sweepResults = sweepFull(nFrames, opts);
        otherwise
            error('Unknown sweep type: %s', opts.Sweep);
    end
    
    if opts.SaveResults
        outDir = './results/sweeps';
        if ~exist(outDir, 'dir'); mkdir(outDir); end
        fname = fullfile(outDir, sprintf('sweep_%s_%s.mat', opts.Sweep, datestr(now,'yyyymmdd_HHMMSS')));
        save(fname, 'sweepResults');
        fprintf('\nSweep results saved to: %s\n', fname);
    end
end

%% ===== Sweep Functions =====

function results = sweepDelaySpread(nFrames, opts)
    % Agreed delay spreads: 30, 100, 300, 1000 ns
    delaySpreads = [30e-9 100e-9 300e-9 1000e-9];
    patterns = {'nr_baseline', 'sparse_half_fd'};
    
    results = struct();
    results.sweepParam = 'DelaySpread';
    results.values = delaySpreads;
    results.patterns = patterns;
    
    for ds = 1:numel(delaySpreads)
        for p = 1:numel(patterns)
            simCfg = evm_pdsch_lls('DelaySpread', delaySpreads(ds), ...
                'NFrames', nFrames, 'SNRdB', -5:3:25);
            dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
            
            fprintf('DS=%dns, Pattern=%s: ', round(delaySpreads(ds)*1e9), patterns{p});
            r = run_pdsch_lls(simCfg, dmrsCfg, 'GenerateDataset', opts.GenerateDataset);
            results.data{ds,p} = r;
        end
    end
end

function results = sweepUESpeed(nFrames, opts)
    % Agreed speeds: 3, 30, 120, 350, 500 km/h
    speeds = [3 30 120 350 500];
    patterns = {'nr_baseline', 'sparse_half_fd'};
    
    results = struct();
    results.sweepParam = 'UESpeed_kmh';
    results.values = speeds;
    results.patterns = patterns;
    
    for s = 1:numel(speeds)
        for p = 1:numel(patterns)
            simCfg = evm_pdsch_lls('UESpeed_kmh', speeds(s), ...
                'NFrames', nFrames, 'SNRdB', -5:3:25);
            dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
            
            fprintf('Speed=%dkm/h, Pattern=%s: ', speeds(s), patterns{p});
            r = run_pdsch_lls(simCfg, dmrsCfg, 'GenerateDataset', opts.GenerateDataset);
            results.data{s,p} = r;
        end
    end
end

function results = sweepFrequency(nFrames, opts)
    % Agreed frequencies: 0.7, 2, 4, 7, 30 GHz
    freqs = [0.7e9 2e9 4e9 7e9 30e9];
    scs =   [15    15   30  30   120];
    patterns = {'nr_baseline', 'sparse_half_fd'};
    
    results = struct();
    results.sweepParam = 'CarrierFreq';
    results.values = freqs;
    results.patterns = patterns;
    
    for f = 1:numel(freqs)
        % Get appropriate antenna config for this frequency
        freqLabel = getFreqLabel(freqs(f));
        antCfgs = antenna_configs(freqLabel);
        antNames = fieldnames(antCfgs);
        antCfg = antCfgs.(antNames{1});  % Use first (simplest) config
        
        for p = 1:numel(patterns)
            simCfg = evm_pdsch_lls('CarrierFreq', freqs(f), ...
                'SubcarrierSpacing', scs(f), ...
                'NTxAnts', antCfg.NTxAnts, ...
                'TxArrayConfig', antCfg.ArrayConfig, ...
                'TxAntSpacing', antCfg.AntSpacing, ...
                'NFrames', nFrames, 'SNRdB', -5:3:25);
            dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
            
            fprintf('Freq=%.1fGHz, Pattern=%s: ', freqs(f)/1e9, patterns{p});
            r = run_pdsch_lls(simCfg, dmrsCfg, 'GenerateDataset', opts.GenerateDataset);
            results.data{f,p} = r;
        end
    end
end

function results = sweepChannelModel(nFrames, opts)
    % Agreed: CDL-A, CDL-C, CDL-D
    channels = {'CDL-A', 'CDL-C', 'CDL-D'};
    patterns = {'nr_baseline', 'sparse_half_fd'};
    
    results = struct();
    results.sweepParam = 'DelayProfile';
    results.values = channels;
    results.patterns = patterns;
    
    for c = 1:numel(channels)
        for p = 1:numel(patterns)
            simCfg = evm_pdsch_lls('DelayProfile', channels{c}, ...
                'NFrames', nFrames, 'SNRdB', -5:3:25);
            dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
            
            fprintf('Channel=%s, Pattern=%s: ', channels{c}, patterns{p});
            r = run_pdsch_lls(simCfg, dmrsCfg, 'GenerateDataset', opts.GenerateDataset);
            results.data{c,p} = r;
        end
    end
end

function results = sweepDMRSPattern(nFrames, opts)
    % Compare all DMRS patterns at reference scenario
    patterns = {'nr_baseline', 'nr_baseline_double', 'sparse_half_fd', ...
                'sparse_td', 'sparse_fd_td', 'sparse_quarter_fd'};
    
    results = struct();
    results.sweepParam = 'DMRSPattern';
    results.values = patterns;
    
    simCfg = evm_pdsch_lls('NFrames', nFrames, 'SNRdB', -5:2:25);
    
    for p = 1:numel(patterns)
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('Pattern=%s (%s): ', patterns{p}, dmrsCfg.OverheadInfo.Description);
        r = run_pdsch_lls(simCfg, dmrsCfg, 'GenerateDataset', opts.GenerateDataset);
        results.data{p} = r;
    end
end

function results = sweepFull(nFrames, opts)
    % Full sweep: all channel models x delay spreads x DMRS patterns
    % at reference frequency (4 GHz)
    channels = {'CDL-A', 'CDL-C', 'CDL-D'};
    delaySpreads = [30e-9 100e-9 300e-9];
    patterns = {'nr_baseline', 'sparse_half_fd', 'sparse_fd_td'};
    
    results = struct();
    results.sweepParam = 'Full';
    results.channels = channels;
    results.delaySpreads = delaySpreads;
    results.patterns = patterns;
    
    total = numel(channels) * numel(delaySpreads) * numel(patterns);
    idx = 0;
    
    for c = 1:numel(channels)
        for ds = 1:numel(delaySpreads)
            for p = 1:numel(patterns)
                idx = idx + 1;
                simCfg = evm_pdsch_lls('DelayProfile', channels{c}, ...
                    'DelaySpread', delaySpreads(ds), ...
                    'NFrames', nFrames, 'SNRdB', -5:3:25);
                dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
                
                fprintf('[%d/%d] %s, DS=%dns, %s: ', idx, total, ...
                    channels{c}, round(delaySpreads(ds)*1e9), patterns{p});
                r = run_pdsch_lls(simCfg, dmrsCfg, ...
                    'GenerateDataset', opts.GenerateDataset);
                results.data{c,ds,p} = r;
            end
        end
    end
end

%% ===== Helpers =====
function label = getFreqLabel(freqHz)
    freqGHz = freqHz / 1e9;
    if freqGHz < 1
        label = '0.7GHz';
    elseif freqGHz < 3
        label = '2GHz';
    elseif freqGHz < 6
        label = '4GHz';
    elseif freqGHz < 15
        label = '7GHz';
    else
        label = '30GHz';
    end
end
