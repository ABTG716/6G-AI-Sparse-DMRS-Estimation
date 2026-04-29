%% generate_ai_dataset.m
% Generate training/validation dataset for AI-based channel estimation.
%
% Produces HDF5 files for two receiver alternatives:
%   Alt 1: Input=LS(DMRS REs) -> Output=denoised H(DMRS REs)
%   Alt 2: Input=LS(DMRS REs) -> Output=H(ALL REs)
%
% Labels (ground truth) for each:
%   1. Ideal:     perfectH from hpre6GPerfectChannelEstimate
%   2. Practical: MMSE estimate at SNR=30dB with same DMRS pattern
%
% Pattern: sparse_fd (Type 2, 8 DMRS REs/PRB, 2 time symbols)
% EVM: 4 GHz, CDL-C, DS=100ns, 30 km/h, 30 kHz SCS, 20 MHz (51 RBs)
%      4Tx, 2Rx, 1 layer

clearvars; close all; clc;
addpath(genpath(pwd));
addpath('C:\Users\rb\Documents\MATLAB\Examples\R2025b\pre6g\LinkLevelSimulationfor6GExample');

%% ===== Configuration =====
SNRValues = 0:2:30;          % 16 SNR levels
SlotsPerSNR = 6400;          % 6400 slots per SNR -> 102,400 total
SNR_label_dB = 30;           % SNR for practical label generation
PatternName = 'sparse_fd';
SaveInterval = 100;          % Print progress every N slots

outDir = './dataset/sparse_fd';
if ~exist(outDir, 'dir'); mkdir(outDir); end

%% ===== Simulation Config =====
simCfg = evm_pdsch_lls( ...
    'CarrierFreq', 4e9, ...
    'SubcarrierSpacing', 30, ...
    'BandwidthMHz', 20, ...
    'DelayProfile', 'CDL-C', ...
    'DelaySpread', 100e-9, ...
    'UESpeed_kmh', 30, ...
    'Modulation', '64QAM', ...
    'TargetCodeRate', 0.65, ...
    'NTxAnts', 4, ...
    'NRxAnts', 2, ...
    'NumLayers', 1, ...
    'EnableHARQ', false, ...
    'NFrames', 1);

dmrsCfg = dmrs_config('PDSCH', 'Pattern', PatternName);

%% ===== Build carrier, PDSCH, channel =====
carrier = pre6GCarrierConfig;
carrier.NSizeGrid = simCfg.NSizeGrid;
carrier.SubcarrierSpacing = simCfg.SubcarrierSpacing;

pdsch = pre6GPDSCHConfig;
pdsch.PRBSet = 0:carrier.NSizeGrid-1;
pdsch.SymbolAllocation = [0, carrier.SymbolsPerSlot];
pdsch.NumLayers = simCfg.NumLayers;
pdsch.Modulation = simCfg.Modulation;
pdsch.DMRS.DMRSConfigurationType = dmrsCfg.DMRSConfigurationType;
pdsch.DMRS.DMRSLength = dmrsCfg.DMRSLength;
pdsch.DMRS.DMRSAdditionalPosition = dmrsCfg.DMRSAdditionalPosition;
pdsch.DMRS.DMRSTypeAPosition = dmrsCfg.DMRSTypeAPosition;
pdsch.DMRS.NumCDMGroupsWithoutData = dmrsCfg.NumCDMGroupsWithoutData;
pdsch.DMRS.DMRSPortSet = dmrsCfg.DMRSPortSet;
if ~isempty(dmrsCfg.NIDNSCID)
    pdsch.DMRS.NIDNSCID = dmrsCfg.NIDNSCID;
end
pdsch.DMRS.NSCID = dmrsCfg.NSCID;
pdsch.EnablePTRS = dmrsCfg.EnablePTRS;

pdschextra = struct();
pdschextra.TargetCodeRate = simCfg.TargetCodeRate;
pdschextra.PRGBundleSize = simCfg.PRGBundleSize;

K = carrier.NSizeGrid * 12;    % 612
L = carrier.SymbolsPerSlot;    % 14
ofdmInfo = hpre6GOFDMInfo(carrier);

% DMRS info (constant for this pattern)
dmrsIndices = hpre6GPDSCHDMRSIndices(carrier, pdsch);
[pdschIndices, pdschIndicesInfo] = hpre6GPDSCHIndices(carrier, pdsch);
nDmrsRE = numel(dmrsIndices(:,1));

% DMRS mask
dmrsMask = false(K, L);
dmrsMask(dmrsIndices(:,1)) = true;

% Channel model
channel = nrCDLChannel;
channel = hArrayGeometry(channel, simCfg.NTxAnts, simCfg.NRxAnts);
nTxAnts = prod(channel.TransmitAntennaArray.Size);
nRxAnts = prod(channel.ReceiveAntennaArray.Size);
channel.DelayProfile = simCfg.DelayProfile;
channel.DelaySpread = simCfg.DelaySpread;
channel.MaximumDopplerShift = simCfg.MaxDopplerShift;
channel.SampleRate = ofdmInfo.SampleRate;
chInfo = info(channel);
maxChDelay = chInfo.MaximumChannelDelay;

% Encoder
encodeDLSCH = hpre6GDLSCH;
encodeDLSCH.MultipleHARQProcesses = false;
encodeDLSCH.TargetCodeRate = pdschextra.TargetCodeRate;

% Noise for practical label at 30 dB
SNR_label = 10^(SNR_label_dB / 10);
N0_label = 1 / sqrt(double(ofdmInfo.Nfft) * SNR_label * nRxAnts);

nSamples = numel(SNRValues) * SlotsPerSNR;

fprintf('===== DATASET GENERATION CONFIG =====\n');
fprintf('Pattern: %s (%s)\n', PatternName, dmrsCfg.OverheadInfo.Description);
fprintf('Grid: %d x %d, DMRS REs: %d, NRx: %d\n', K, L, nDmrsRE, nRxAnts);
fprintf('SNR range: %d to %d dB (%d levels)\n', SNRValues(1), SNRValues(end), numel(SNRValues));
fprintf('Slots per SNR: %d, Total samples: %d\n', SlotsPerSNR, nSamples);
fprintf('Practical label SNR: %d dB\n', SNR_label_dB);
fprintf('=====================================\n\n');

%% ===== Create HDF5 file =====
% Single file with all data for both Alt 1 and Alt 2
h5File = fullfile(outDir, 'dataset_sparse_fd.h5');
if exist(h5File, 'file'); delete(h5File); end

% --- Input (shared by Alt 1 and Alt 2) ---
h5create(h5File, '/input_ls_real', [K L nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [K L nRxAnts 1], 'Deflate', 4);
h5create(h5File, '/input_ls_imag', [K L nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [K L nRxAnts 1], 'Deflate', 4);

% --- DMRS mask (write once) ---
h5create(h5File, '/dmrs_mask', [K L], 'Datatype', 'single');

% --- Alt 1 labels: H at DMRS positions only ---
% Ideal (perfect channel)
h5create(h5File, '/alt1_ideal_real', [nDmrsRE nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [nDmrsRE nRxAnts 1], 'Deflate', 4);
h5create(h5File, '/alt1_ideal_imag', [nDmrsRE nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [nDmrsRE nRxAnts 1], 'Deflate', 4);
% Practical (MMSE at 30 dB)
h5create(h5File, '/alt1_pract_real', [nDmrsRE nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [nDmrsRE nRxAnts 1], 'Deflate', 4);
h5create(h5File, '/alt1_pract_imag', [nDmrsRE nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [nDmrsRE nRxAnts 1], 'Deflate', 4);

% --- Alt 2 labels: H at ALL REs ---
% Ideal (perfect channel)
h5create(h5File, '/alt2_ideal_real', [K L nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [K L nRxAnts 1], 'Deflate', 4);
h5create(h5File, '/alt2_ideal_imag', [K L nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [K L nRxAnts 1], 'Deflate', 4);
% Practical (MMSE at 30 dB, interpolated to all REs)
h5create(h5File, '/alt2_pract_real', [K L nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [K L nRxAnts 1], 'Deflate', 4);
h5create(h5File, '/alt2_pract_imag', [K L nRxAnts nSamples], ...
    'Datatype', 'single', 'ChunkSize', [K L nRxAnts 1], 'Deflate', 4);

% --- Metadata per sample ---
h5create(h5File, '/snr_db', [1 nSamples], 'Datatype', 'single');
h5create(h5File, '/rms_norm', [1 nSamples], 'Datatype', 'single');
h5create(h5File, '/slot_idx', [1 nSamples], 'Datatype', 'int32');

% --- Static metadata ---
h5create(h5File, '/dmrs_indices', [nDmrsRE 1], 'Datatype', 'int32');
h5write(h5File, '/dmrs_indices', int32(dmrsIndices(:,1)));
h5write(h5File, '/dmrs_mask', single(dmrsMask));

nDataRE = numel(pdschIndices(:,1));
h5create(h5File, '/data_indices', [nDataRE 1], 'Datatype', 'int32');
h5write(h5File, '/data_indices', int32(pdschIndices(:,1)));

fprintf('HDF5 file: %s\n\n', h5File);

%% ===== Main generation loop =====
sampleIdx = 0;
totalTime = tic;

for snrIdx = 1:numel(SNRValues)
    SNRdB_val = SNRValues(snrIdx);
    SNR = 10^(SNRdB_val / 10);
    N0 = 1 / sqrt(double(ofdmInfo.Nfft) * SNR * nRxAnts);
    
    % New channel seed per SNR
    release(channel);
    channel.Seed = randi([0 2^32-1]);
    reset(channel);
    
    % Initial precoder
    estChannelGrid = getInitialChannelEstimate(carrier, nTxAnts, channel);
    wtx = hSVDPrecoders(carrier, pdsch, estChannelGrid, pdschextra.PRGBundleSize);
    
    snrTic = tic;
    
    for slotNum = 0:SlotsPerSNR-1
        carrier.NSlot = slotNum;
        sampleIdx = sampleIdx + 1;
        
        % ---- Generate and transmit ----
        trBlkSizes = hpre6GTBS(pdsch, pdschextra.TargetCodeRate);
        trBlk = randi([0 1], trBlkSizes, 1);
        setTransportBlock(encodeDLSCH, trBlk);
        codedTrBlocks = encodeDLSCH(pdschIndicesInfo.Qm, ...
            pdsch.NumLayers, pdschIndicesInfo.G, 0);
        
        [txWaveform, ~] = hPDSCHTransmit(carrier, pdsch, codedTrBlocks, wtx);
        
        % ---- Channel ----
        txWaveform = [txWaveform; zeros(maxChDelay, size(txWaveform, 2))]; %#ok<AGROW>
        [rxWaveform, pathGains, sampleTimes] = channel(txWaveform);
        
        % ---- Add noise at ACTUAL SNR (for input) ----
        noise = N0 * randn(size(rxWaveform), "like", rxWaveform);
        rxWaveform_noisy = rxWaveform + noise;
        
        % ---- Add noise at 30 dB (for practical label) ----
        noise_label = N0_label * randn(size(rxWaveform), "like", rxWaveform);
        rxWaveform_label = rxWaveform + noise_label;
        
        % ---- Perfect timing (same for both) ----
        pathFilters = getPathFilters(channel);
        offset = nrPerfectTimingEstimate(pathGains, pathFilters);
        
        % ---- Perfect channel (ideal label) ----
        perfectH_ant = hpre6GPerfectChannelEstimate( ...
            carrier, pathGains, pathFilters, offset, sampleTimes);
        % K x L x NRx x NTx -> port domain K x L x NRx
        perfectH_port = applyPrecoder(perfectH_ant, wtx, K, L, nRxAnts);
        
        % ---- OFDM demod at actual SNR (for LS input) ----
        rxGrid = hpre6GOFDMDemodulate(carrier, rxWaveform_noisy(1+offset:end, :));
        
        % ---- OFDM demod at 30 dB (for practical label) ----
        rxGrid_label = hpre6GOFDMDemodulate(carrier, rxWaveform_label(1+offset:end, :));
        
        % ---- DMRS symbols ----
        dmrsSym = hpre6GPDSCHDMRS(carrier, pdsch);
        dmrsInd = hpre6GPDSCHDMRSIndices(carrier, pdsch);
        
        % ---- Compute LS estimate at DMRS (input) ----
        lsReal = zeros(K, L, nRxAnts, 'single');
        lsImag = zeros(K, L, nRxAnts, 'single');
        for rx = 1:nRxAnts
            lsEst = rxGrid(:,:,rx);
            lsEst = lsEst(dmrsInd(:,1)) ./ dmrsSym(:,1);
            tmp = zeros(K, L, 'single');
            tmp(dmrsInd(:,1)) = single(real(lsEst));
            lsReal(:,:,rx) = tmp;
            tmp(:) = 0;
            tmp(dmrsInd(:,1)) = single(imag(lsEst));
            lsImag(:,:,rx) = tmp;
        end
        
        % ---- Per-sample RMS normalization ----
        allLsVals = [];
        for rx = 1:nRxAnts
            rr = lsReal(:,:,rx); ii = lsImag(:,:,rx);
            vals = complex(rr(dmrsMask), ii(dmrsMask));
            allLsVals = [allLsVals; vals]; %#ok<AGROW>
        end
        rmsNorm = single(sqrt(mean(abs(allLsVals).^2)));
        if rmsNorm < 1e-10; rmsNorm = single(1.0); end
        
        % Normalize input
        lsReal_n = lsReal / rmsNorm;
        lsImag_n = lsImag / rmsNorm;
        
        % ---- Ideal labels (normalized) ----
        idealH_real = single(real(perfectH_port)) / rmsNorm;
        idealH_imag = single(imag(perfectH_port)) / rmsNorm;
        
        % Alt 1 ideal: extract at DMRS positions
        alt1_ideal_r = zeros(nDmrsRE, nRxAnts, 'single');
        alt1_ideal_i = zeros(nDmrsRE, nRxAnts, 'single');
        for rx = 1:nRxAnts
            alt1_ideal_r(:,rx) = idealH_real(dmrsInd(:,1) + (rx-1)*K*L);
            alt1_ideal_i(:,rx) = idealH_imag(dmrsInd(:,1) + (rx-1)*K*L);
        end
        
        % ---- Practical labels: MMSE at 30 dB (normalized) ----
        % Full channel estimate using hpre6GChannelEstimate at 30 dB
        [estH_label, ~] = hpre6GChannelEstimate(carrier, rxGrid_label, ...
            dmrsInd, dmrsSym, 'CDMLengths', pdsch.DMRS.CDMLengths);
        % estH_label is K x L x NRx (port domain, after practical CE)
        
        practH_real = single(real(estH_label)) / rmsNorm;
        practH_imag = single(imag(estH_label)) / rmsNorm;
        
        % Alt 1 practical: extract at DMRS positions
        alt1_pract_r = zeros(nDmrsRE, nRxAnts, 'single');
        alt1_pract_i = zeros(nDmrsRE, nRxAnts, 'single');
        for rx = 1:nRxAnts
            hSlice_r = practH_real(:,:,rx);
            hSlice_i = practH_imag(:,:,rx);
            alt1_pract_r(:,rx) = hSlice_r(dmrsInd(:,1));
            alt1_pract_i(:,rx) = hSlice_i(dmrsInd(:,1));
        end
        
        % ---- Write to HDF5 ----
        % Input (shared)
        h5write(h5File, '/input_ls_real', lsReal_n, [1 1 1 sampleIdx], [K L nRxAnts 1]);
        h5write(h5File, '/input_ls_imag', lsImag_n, [1 1 1 sampleIdx], [K L nRxAnts 1]);
        
        % Alt 1 labels
        h5write(h5File, '/alt1_ideal_real', alt1_ideal_r, [1 1 sampleIdx], [nDmrsRE nRxAnts 1]);
        h5write(h5File, '/alt1_ideal_imag', alt1_ideal_i, [1 1 sampleIdx], [nDmrsRE nRxAnts 1]);
        h5write(h5File, '/alt1_pract_real', alt1_pract_r, [1 1 sampleIdx], [nDmrsRE nRxAnts 1]);
        h5write(h5File, '/alt1_pract_imag', alt1_pract_i, [1 1 sampleIdx], [nDmrsRE nRxAnts 1]);
        
        % Alt 2 labels
        h5write(h5File, '/alt2_ideal_real', idealH_real, [1 1 1 sampleIdx], [K L nRxAnts 1]);
        h5write(h5File, '/alt2_ideal_imag', idealH_imag, [1 1 1 sampleIdx], [K L nRxAnts 1]);
        h5write(h5File, '/alt2_pract_real', practH_real, [1 1 1 sampleIdx], [K L nRxAnts 1]);
        h5write(h5File, '/alt2_pract_imag', practH_imag, [1 1 1 sampleIdx], [K L nRxAnts 1]);
        
        % Metadata
        h5write(h5File, '/snr_db', single(SNRdB_val), [1 sampleIdx], [1 1]);
        h5write(h5File, '/rms_norm', rmsNorm, [1 sampleIdx], [1 1]);
        h5write(h5File, '/slot_idx', int32(slotNum), [1 sampleIdx], [1 1]);
        
        % Update precoder
        wtx = hSVDPrecoders(carrier, pdsch, perfectH_ant, pdschextra.PRGBundleSize);
        
        % Progress
        if mod(slotNum+1, SaveInterval) == 0
            elapsed = toc(snrTic);
            eta_snr = elapsed / (slotNum+1) * (SlotsPerSNR - slotNum - 1);
            fprintf('  SNR=%+3d dB: %d/%d slots (%.0fs elapsed, ~%.0fs remaining)\n', ...
                SNRdB_val, slotNum+1, SlotsPerSNR, elapsed, eta_snr);
        end
    end
    
    snrTime = toc(snrTic);
    totalElapsed = toc(totalTime);
    etaTotal = totalElapsed / snrIdx * (numel(SNRValues) - snrIdx);
    fprintf('SNR=%+3d dB: DONE (%d samples, %.1f min, ETA total: %.1f min)\n', ...
        SNRdB_val, SlotsPerSNR, snrTime/60, etaTotal/60);
end

totalElapsed = toc(totalTime);

%% ===== Write metadata attributes =====
h5writeatt(h5File, '/', 'pattern', PatternName);
h5writeatt(h5File, '/', 'carrier_freq_hz', simCfg.CarrierFreq);
h5writeatt(h5File, '/', 'scs_khz', simCfg.SubcarrierSpacing);
h5writeatt(h5File, '/', 'bandwidth_mhz', simCfg.BandwidthMHz);
h5writeatt(h5File, '/', 'n_size_grid', simCfg.NSizeGrid);
h5writeatt(h5File, '/', 'delay_profile', simCfg.DelayProfile);
h5writeatt(h5File, '/', 'delay_spread_ns', simCfg.DelaySpread * 1e9);
h5writeatt(h5File, '/', 'ue_speed_kmh', simCfg.UESpeed_kmh);
h5writeatt(h5File, '/', 'doppler_hz', simCfg.MaxDopplerShift);
h5writeatt(h5File, '/', 'n_tx_ants', int32(nTxAnts));
h5writeatt(h5File, '/', 'n_rx_ants', int32(nRxAnts));
h5writeatt(h5File, '/', 'num_layers', int32(simCfg.NumLayers));
h5writeatt(h5File, '/', 'modulation', simCfg.Modulation);
h5writeatt(h5File, '/', 'n_subcarriers', int32(K));
h5writeatt(h5File, '/', 'n_symbols', int32(L));
h5writeatt(h5File, '/', 'n_dmrs_re', int32(nDmrsRE));
h5writeatt(h5File, '/', 'dmrs_type', int32(dmrsCfg.DMRSConfigurationType));
h5writeatt(h5File, '/', 'dmrs_add_pos', int32(dmrsCfg.DMRSAdditionalPosition));
h5writeatt(h5File, '/', 'cdm_groups_no_data', int32(dmrsCfg.NumCDMGroupsWithoutData));
h5writeatt(h5File, '/', 'snr_min_db', int32(SNRValues(1)));
h5writeatt(h5File, '/', 'snr_max_db', int32(SNRValues(end)));
h5writeatt(h5File, '/', 'snr_step_db', int32(SNRValues(2)-SNRValues(1)));
h5writeatt(h5File, '/', 'practical_label_snr_db', int32(SNR_label_dB));
h5writeatt(h5File, '/', 'slots_per_snr', int32(SlotsPerSNR));
h5writeatt(h5File, '/', 'total_samples', int32(sampleIdx));
h5writeatt(h5File, '/', 'normalization', 'per_sample_rms_of_ls');

%% ===== Verification =====
fprintf('\n===== VERIFICATION =====\n');

% Check first and last sample
for checkIdx = [1, sampleIdx]
    in_r = h5read(h5File, '/input_ls_real', [1 1 1 checkIdx], [K L nRxAnts 1]);
    in_i = h5read(h5File, '/input_ls_imag', [1 1 1 checkIdx], [K L nRxAnts 1]);
    snr_val = h5read(h5File, '/snr_db', [1 checkIdx], [1 1]);
    rms_val = h5read(h5File, '/rms_norm', [1 checkIdx], [1 1]);
    
    % Alt 2 ideal label
    lab_r = h5read(h5File, '/alt2_ideal_real', [1 1 1 checkIdx], [K L nRxAnts 1]);
    lab_i = h5read(h5File, '/alt2_ideal_imag', [1 1 1 checkIdx], [K L nRxAnts 1]);
    
    % Alt 2 practical label
    plab_r = h5read(h5File, '/alt2_pract_real', [1 1 1 checkIdx], [K L nRxAnts 1]);
    plab_i = h5read(h5File, '/alt2_pract_imag', [1 1 1 checkIdx], [K L nRxAnts 1]);
    
    fprintf('\nSample %d: SNR=%.0f dB, RMS=%.4f\n', checkIdx, snr_val, rms_val);
    fprintf('  Input nonzero REs (Rx0): %d (expected %d)\n', nnz(in_r(:,:,1)), nDmrsRE);
    
    mask = logical(h5read(h5File, '/dmrs_mask'));
    for rx = 1:nRxAnts
        ls_c = complex(in_r(:,:,rx), in_i(:,:,rx));
        hi_c = complex(lab_r(:,:,rx), lab_i(:,:,rx));
        hp_c = complex(plab_r(:,:,rx), plab_i(:,:,rx));
        
        % NMSE at DMRS: LS vs ideal
        ls_d = ls_c(mask); hi_d = hi_c(mask);
        nmse_ls = sum(abs(ls_d - hi_d).^2) / sum(abs(hi_d).^2);
        
        % NMSE at DMRS: practical vs ideal
        hp_d = hp_c(mask);
        nmse_pr = sum(abs(hp_d - hi_d).^2) / sum(abs(hi_d).^2);
        
        % NMSE at ALL REs: practical vs ideal
        nmse_all = sum(abs(hp_c(:) - hi_c(:)).^2) / sum(abs(hi_c(:)).^2);
        
        fprintf('  Rx%d: NMSE(LS vs ideal @DMRS)=%.1f dB, NMSE(pract vs ideal @DMRS)=%.1f dB, NMSE(pract vs ideal @ALL)=%.1f dB\n', ...
            rx-1, 10*log10(nmse_ls), 10*log10(nmse_pr), 10*log10(nmse_all));
    end
end

fileInfo = dir(h5File);
fprintf('\n===== GENERATION COMPLETE =====\n');
fprintf('Total samples: %d\n', sampleIdx);
fprintf('Total time: %.1f min (%.1f hours)\n', totalElapsed/60, totalElapsed/3600);
fprintf('File: %s (%.1f GB)\n', h5File, fileInfo.bytes/1e9);
fprintf('\nDataset structure (single HDF5 file):\n');
fprintf('  /input_ls_real, /input_ls_imag: [%d,%d,%d,N] LS at DMRS (zero elsewhere)\n', K, L, nRxAnts);
fprintf('  /dmrs_mask: [%d,%d] binary mask\n', K, L);
fprintf('  /alt1_ideal_real/imag: [%d,%d,N] perfect H at DMRS only\n', nDmrsRE, nRxAnts);
fprintf('  /alt1_pract_real/imag: [%d,%d,N] MMSE@30dB H at DMRS only\n', nDmrsRE, nRxAnts);
fprintf('  /alt2_ideal_real/imag: [%d,%d,%d,N] perfect H at ALL REs\n', K, L, nRxAnts);
fprintf('  /alt2_pract_real/imag: [%d,%d,%d,N] MMSE@30dB H at ALL REs\n', K, L, nRxAnts);
fprintf('  /snr_db, /rms_norm, /slot_idx: per-sample metadata\n');
fprintf('  All normalized by per-sample RMS of LS estimates\n');

%% ===== Local functions =====
% function perfectH_port = applyPrecoder(perfectH_ant, wtx, K, L, nRxAnts)
%     % Convert antenna-domain perfect H to port domain
%     % perfectH_ant: K x L x NRx x NTx
%     % wtx: various shapes from hSVDPrecoders
%     % Output: K x L x NRx (for NLayers=1)
    
function perfectH_port = applyPrecoder(perfectH_ant, wtx, K, L, nRxAnts)
    % Convert antenna-domain perfect H to port domain
    % perfectH_ant: K x L x NRx x NTx
    % wtx: from hSVDPrecoders — shape varies
    % Output: K x L x NRx (for NLayers=1)
    
    persistent dbg;
    if isempty(dbg)
        fprintf('  [applyPrecoder] wtx size=[%s], class=%s, perfectH size=[%s]\n', ...
            num2str(size(wtx)), class(wtx), num2str(size(perfectH_ant)));
        dbg = true;
    end
    
    NTx = size(perfectH_ant, 4);
    perfectH_port = zeros(K, L, nRxAnts, 'single');
    
    % hSVDPrecoders returns wtx as NLayers x NTx x nPRGs
    % Actual observed: [1, 4] for 1 layer, 4 Tx, wideband
    % We need a NTx x 1 column vector for H_ant * w multiplication
    
    % Normalize to always get NTx x NLayers x nPRGs
    sz = size(wtx);
    if ndims(wtx) == 2
        % Could be [NLayers, NTx] or [NTx, NLayers]
        if sz(1) == NTx
            w = wtx(:, 1);  % Already NTx x NLayers, take first layer
        else
            w = wtx(1, :).';  % NLayers x NTx, transpose first layer
        end
        % Single precoder for all subcarriers
        for sym = 1:L
            for rx = 1:nRxAnts
                h_ant = reshape(perfectH_ant(:, sym, rx, :), K, NTx);
                perfectH_port(:, sym, rx) = single(h_ant * w);
            end
        end
    elseif ndims(wtx) == 3
        % NLayers x NTx x nPRGs or NTx x NLayers x nPRGs
        nPRGs = sz(3);
        scPerPRG = ceil(K / nPRGs);
        for sym = 1:L
            for rx = 1:nRxAnts
                h_ant = reshape(perfectH_ant(:, sym, rx, :), K, NTx);
                h_port = zeros(K, 1, 'like', h_ant);
                for prg = 1:nPRGs
                    scStart = (prg-1)*scPerPRG + 1;
                    scEnd = min(prg*scPerPRG, K);
                    wSlice = wtx(:, :, prg);
                    if size(wSlice, 1) == NTx
                        w = wSlice(:, 1);
                    else
                        w = wSlice(1, :).';
                    end
                    h_port(scStart:scEnd) = h_ant(scStart:scEnd, :) * w;
                end
                perfectH_port(:, sym, rx) = single(h_port);
            end
        end
    end
end

function estChannelGrid = getInitialChannelEstimate(carrier, nTxAnts, propchannel)
    ofdmInfo = hpre6GOFDMInfo(carrier);
    chInfo = info(propchannel);
    maxChDelay = chInfo.MaximumChannelDelay;
    tmpWaveform = zeros( ...
        (ofdmInfo.SampleRate/1000/carrier.SlotsPerSubframe) + maxChDelay, ...
        nTxAnts, "single");
    [~, pathGains, sampleTimes] = propchannel(tmpWaveform);
    pathFilters = getPathFilters(propchannel);
    offset = nrPerfectTimingEstimate(pathGains, pathFilters);
    estChannelGrid = hpre6GPerfectChannelEstimate( ...
        carrier, pathGains, pathFilters, offset, sampleTimes);
end
