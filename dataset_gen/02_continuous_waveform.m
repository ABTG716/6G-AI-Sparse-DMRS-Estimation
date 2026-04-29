%% Continuous multi-slot 5G NR simulation (single OFDM waveform)
% Multi-user-ready (numUsers variable) + LS DMRS channel estimator
% Snapshots are frames*slotsPerFrame (default 20*20 = 400)

clc; clear;

% ---------- Simulation Parameters ----------
SNRdB = 10;

% Specify frames and slots-per-frame so frames*slotsPerFrame = total snapshots
frames = 20;
slotsPerFrame = 20;
totalNoSlots = frames * slotsPerFrame;   % -> 400 by default

perfectEstimation = false;  % set true to use perfect (from ofdmChannelResponse)
rng("default");

% ---------- Multi-user / PDSCH defaults ----------
numUsers = 1;   % change >1 later to create more user PDCH configs
% We'll put user-specific pdsch configs into a cell so scaling to multi-user is easy
userPDSCH = cell(numUsers,1);

% Base PDsch template (you can customize per-user later)
basePdsch = nrPDSCHConfig;
basePdsch.Modulation = "QPSK";
basePdsch.NumLayers = 1;
basePdsch.PRBSet = 0:7;
basePdsch.SymbolAllocation = [0 14];
basePdsch.DMRS.DMRSTypeAPosition = 2;
basePdsch.DMRS.DMRSLength = 1;
basePdsch.DMRS.DMRSAdditionalPosition = 1;
basePdsch.DMRS.DMRSConfigurationType = 1;
basePdsch.DMRS.NumCDMGroupsWithoutData = 2;   % Comb-2 density

for u = 1:numUsers
    % create per-user copy (later you can set different PRBSet, MCS, layers)
    userPDSCH{u} = basePdsch;
    % e.g. userPDSCH{u}.PRBSet = (u-1)*8 + (0:7);  % example different PRBs
end

% ---------- Coding Rate (for 1 codeword assumed) ----------
if basePdsch.NumCodewords == 1
    codeRate = 340/1024;
else
    codeRate = [490 490]./1024;
end

% ---------- DL-SCH Encoder/Decoder (No HARQ) ----------
encodeDLSCH = nrDLSCH;
encodeDLSCH.MultipleHARQProcesses = false;
encodeDLSCH.TargetCodeRate = codeRate;

decodeDLSCH = nrDLSCHDecoder;
decodeDLSCH.MultipleHARQProcesses = false;
decodeDLSCH.TargetCodeRate = codeRate;
decodeDLSCH.LDPCDecodingAlgorithm = "Normalized min-sum";
decodeDLSCH.MaximumLDPCIterationCount = 30;

% ---------- MIMO ----------
nTxAnts = 4;
nRxAnts = 1;   % keep 1 for now; LS estimator works with per-antenna DMRS knowledge

% ---------- Channel (continuous) ----------
channel = nrCDLChannel;
channel.DelayProfile = "CDL-A";
channel.DelaySpread = 300e-9;

channel.TransmitAntennaArray.Size = [nTxAnts 1 1 1 1];
channel.ReceiveAntennaArray.Size  = [nRxAnts 1 1 1 1];

fc = 4e9;
v_kmph = 5;
v = v_kmph * 1000/3600;     % m/s
c = 3e8;
fd = (v/c) * fc;
channel.MaximumDopplerShift = fd;

% Keep ofdm-response (you wanted OFDM timing responses)
carrier = nrCarrierConfig;
carrier.SubcarrierSpacing = 30;
carrier.NSizeGrid = 8;   % 8 PRBs
carrier.NStartGrid = 0;
carrier.CyclicPrefix = "Normal";

ofdmInfo = nrOFDMInfo(carrier);
channel.SampleRate = ofdmInfo.SampleRate;
channel.ChannelResponseOutput = 'ofdm-response';

% ---------- Prepare big resource grid (all slots) ----------
numSC = carrier.NSizeGrid * 12;
numSym = carrier.SymbolsPerSlot;
totalSym = numSym * totalNoSlots;

% bigGrid: [subcarriers x totalSymbols x TxAnts]
bigGrid = zeros(numSC, totalSym, nTxAnts);

% Cells to store per-slot metadata so we can decode later (and to support multi-user later)
pdschIndicesCell = cell(totalNoSlots,1);
pdschInfoCell    = cell(totalNoSlots,1);
dmrsIndicesCell  = cell(totalNoSlots,1);
dmrsSymbolsCell  = cell(totalNoSlots,1);
trBlkSizesCell   = cell(totalNoSlots,1);

% We'll also store each slot's pdschGrid (for TX-layer extraction)
pdschGridSlots = cell(totalNoSlots,1);

% For multi-user you would create multiple pdschGrids per slot and sum them into pdschGrid.

% ---------- Build per-slot grids and place them into bigGrid ----------
for nSlot = 0:totalNoSlots-1
    
    carrier.NSlot = nSlot;                      % needed to compute indices correctly
    slotIdx = nSlot + 1;
    slotSymStart = nSlot * numSym + 1;
    slotSymEnd   = (nSlot+1) * numSym;
    
    % For now: single user. Later extend to loop over users and pack multiple PDSCHs
    pdsch = userPDSCH{1};
    
    [pdschIndices,pdschInfo] = nrPDSCHIndices(carrier,pdsch);
    pdschInfoCell{slotIdx} = pdschInfo;
    pdschIndicesCell{slotIdx} = pdschIndices;
    
    trBlkSizes = nrTBS(pdsch.Modulation,pdsch.NumLayers,...
        numel(pdsch.PRBSet),pdschInfo.NREPerPRB,codeRate,0);
    trBlkSizesCell{slotIdx} = trBlkSizes;

    %% Always new transport block
    for cwIdx = 1:pdsch.NumCodewords
        trBlk = randi([0 1],trBlkSizes(cwIdx),1);
        setTransportBlock(encodeDLSCH,trBlk,cwIdx-1);
    end
    rv = 0;
    codedTrBlock = encodeDLSCH(pdsch.Modulation,pdsch.NumLayers,pdschInfo.G,rv);

    %% PDSCH Modulation (single-slot)
    pdschSymbols = nrPDSCH(carrier,pdsch,codedTrBlock);   % symbols per layer

    %% Research-grade random normalized precoder (4x1)

    w = (randn(nTxAnts,1) + 1i*randn(nTxAnts,1));
    w = w / norm(w);                 % unit norm

    precodingWeights = w.';          % 1 x 4
    precoderDataset(:,slotIdx) = w;
    pdschSymbolsPrecoded = pdschSymbols * precodingWeights;

    %% DMRS for this slot
    dmrsSymbols = nrPDSCHDMRS(carrier,pdsch);
    dmrsIndices = nrPDSCHDMRSIndices(carrier,pdsch);
    dmrsSymbolsCell{slotIdx} = dmrsSymbols;
    dmrsIndicesCell{slotIdx} = dmrsIndices;

    %% Make pdschGrid for this slot and place PDSCH+DMRS
    pdschGrid = nrResourceGrid(carrier, nTxAnts);  % single-slot grid
    [~,pdschAntIndices] = nrExtractResources(pdschIndices,pdschGrid);
    pdschGrid(pdschAntIndices) = pdschSymbolsPrecoded;
    for p = 1:size(dmrsSymbols,2)
        [~,dmrsAntIndices] = nrExtractResources(dmrsIndices(:,p),pdschGrid);
        % add DMRS to the per-antenna grid using precoding weights
        pdschGrid(dmrsAntIndices) = pdschGrid(dmrsAntIndices) + dmrsSymbols(:,p)*precodingWeights(p,:);
    end

    % Store per-slot pdschGrid for TX-layer extraction and for LS estimation later
    pdschGridSlots{slotIdx} = pdschGrid;

    % Put this slot's pdschGrid into the corresponding columns in bigGrid
    bigGrid(:, slotSymStart:slotSymEnd, :) = pdschGrid;
end

% ---------- One-time OFDM modulation of the whole multi-slot grid ----------
carrier.NSlot = 0;   % starting slot index for the big grid
[txWaveform,waveformInfo] = nrOFDMModulate(carrier,bigGrid);

% pad for channel max delay
chInfo = info(channel);
txWaveform = [txWaveform; zeros(chInfo.MaximumChannelDelay,size(txWaveform,2))];

% ---------- Channel: single call for entire waveform (continuous time) ----------
% Channel expects carrier as input.
[rxWaveform,ofdmChannelResponse,timingOffset] = channel(txWaveform,carrier);

% ---------- AWGN (single add) ----------
[noise,nVar] = generateAWGN(SNRdB, txWaveform, nRxAnts);
rxWaveform = rxWaveform + noise;

% Trim initial timing offset (align waveform)
if exist('timingOffset','var') && ~isempty(timingOffset)
    rxWaveform = rxWaveform(1+timingOffset:end,:);
end

% ---------- OFDM demodulate the full received waveform -> full rxGrid ----------
carrier.NSlot = 0;   % must match modulation start
rxGridFull = nrOFDMDemodulate(carrier,rxWaveform);   % size: numSC x totalSym x nRxAnts

% ---------- Now process per-slot: LS estimation, equalize, decode, dataset store ----------
totalBlockErrors = 0;

inputDataset  = zeros(numSC, numSym, 2, totalNoSlots);
targetDataset = zeros(numSC, numSym, nTxAnts, 2, totalNoSlots);
txDataset     = zeros(numSC, numSym, 2, totalNoSlots);
% precoderDataset = zeros(nTxAnts,totalNoSlots) + 1i*zeros(nTxAnts,totalNoSlots);

for nSlot = 0:totalNoSlots-1

    pdsch = userPDSCH{1};
    slotIdx = nSlot + 1;
    slotSymStart = nSlot * numSym + 1;
    slotSymEnd   = (nSlot+1) * numSym;

    % Slice received grid and true channel
    rxGrid = rxGridFull(:, slotSymStart:slotSymEnd, :);              
    ofdmChSlot = ofdmChannelResponse(:, slotSymStart:slotSymEnd, :); 

    % ------------------------------------------------------------
    % Store FULL 4x1 channel tensor (TARGET)
    % ------------------------------------------------------------
    for tx = 1:nTxAnts
        targetDataset(:,:,tx,1,slotIdx) = real(ofdmChSlot(:,:,tx));
        targetDataset(:,:,tx,2,slotIdx) = imag(ofdmChSlot(:,:,tx));
    end

    % ------------------------------------------------------------
    % Store transmitted layer (for reference)
    % ------------------------------------------------------------
    pdschGrid = pdschGridSlots{slotIdx};    
    txLayer = squeeze(pdschGrid(:,:,1));    
    txDataset(:,:,1,slotIdx) = real(txLayer);
    txDataset(:,:,2,slotIdx) = imag(txLayer);

    % ------------------------------------------------------------
    % Store received grid (INPUT)
    % ------------------------------------------------------------
    rxLayer = squeeze(rxGrid(:,:,1));      
    inputDataset(:,:,1,slotIdx) = real(rxLayer);
    inputDataset(:,:,2,slotIdx) = imag(rxLayer);

    % ------------------------------------------------------------
    % Retrieve precoder used during transmission
    % ------------------------------------------------------------
    w = precoderDataset(:,slotIdx);

    % ------------------------------------------------------------
    % LS Channel Estimation using DMRS
    % ------------------------------------------------------------
    estChGridAnts = zeros(numSC, numSym, nTxAnts);
    dmrsMask = false(numSC, numSym);

    pdschGrid = pdschGridSlots{slotIdx};
    rxGridSlot = rxGrid;

    for p = 1:size(dmrsSymbolsCell{slotIdx},2)

        [txDmrs, txAntIdx] = nrExtractResources(dmrsIndicesCell{slotIdx}(:,p), pdschGrid);
        [rxDmrs, ~] = nrExtractResources(dmrsIndicesCell{slotIdx}(:,p), rxGridSlot);

        Ndmrs = size(txDmrs,1);

        for i = 1:Ndmrs

            [scIdx, symIdx, ~] = ind2sub(size(pdschGrid), txAntIdx(i));

            for tx = 1:nTxAnts
                x = txDmrs(i,tx);
                y = rxDmrs(i,1);

                if abs(x) > 1e-12
                    estChGridAnts(scIdx, symIdx, tx) = y / x;
                end
            end

            dmrsMask(scIdx, symIdx) = true;
        end
    end

    % ------------------------------------------------------------
    % Interpolation
    % ------------------------------------------------------------
    [knownSC, knownSYM] = find(dmrsMask);

    if ~isempty(knownSC)

        for tx = 1:nTxAnts

            vals = zeros(length(knownSC),1);
            for k = 1:length(knownSC)
                vals(k) = estChGridAnts(knownSC(k), knownSYM(k), tx);
            end

            F = scatteredInterpolant(double(knownSC), double(knownSYM), ...
                vals, 'linear', 'nearest');

            for sc = 1:numSC
                for sym = 1:numSym
                    if ~dmrsMask(sc,sym)
                        estChGridAnts(sc,sym,tx) = F(sc,sym);
                    end
                end
            end
        end

    else
        estChGridAnts = ofdmChSlot;
    end

    noiseEst = nVar * waveformInfo.Nfft;

    % ------------------------------------------------------------
    % Convert antenna-domain to layer-domain using TRUE precoder
    % ------------------------------------------------------------
    % Compute effective channel H_eff = H * w
    estChGridLayers = zeros(numSC,numSym,1);

    for tx = 1:nTxAnts
        estChGridLayers(:,:,1) = estChGridLayers(:,:,1) + ...
            estChGridAnts(:,:,tx) * w(tx);
    end

    % ------------------------------------------------------------
    % Equalization & Decoding
    % ------------------------------------------------------------
    pdschIndices = pdschIndicesCell{slotIdx};

    rxLayerGrid = reshape(rxLayer, numSC, numSym, 1);

    [pdschRx,pdschHest] = nrExtractResources(pdschIndices, rxLayerGrid, estChGridLayers);
    [pdschEq,csi] = nrEqualizeMMSE(pdschRx, pdschHest, noiseEst);

    [dlschLLRs,rxSymbols] = nrPDSCHDecode(carrier, pdsch, pdschEq, noiseEst);

    csi = nrLayerDemap(csi);

    for cwIdx = 1:pdsch.NumCodewords
        Qm = length(dlschLLRs{cwIdx})/length(rxSymbols{cwIdx});
        csi{cwIdx} = repmat(csi{cwIdx}.',Qm,1);
        dlschLLRs{cwIdx} = dlschLLRs{cwIdx} .* csi{cwIdx}(:);
    end

    reset(decodeDLSCH);
    decodeDLSCH.TransportBlockLength = trBlkSizesCell{slotIdx};
    [~,blkerr] = decodeDLSCH(dlschLLRs, pdsch.Modulation, pdsch.NumLayers, 0);

    blockError = any(blkerr);
    totalBlockErrors = totalBlockErrors + blockError;

    disp("Slot "+nSlot+" Block Error = "+blockError);
end

BLER = totalBlockErrors / totalNoSlots;
disp("Final BLER = " + BLER);

%% (Optional) Export dataset to CSV or MAT
% save('TF_y_x_H_dataset_continuous_LS.mat','inputDataset','txDataset','targetDataset','SNRdB','totalNoSlots');

%% ------------------- Helper functions -------------------
function [noise,nVar] = generateAWGN(SNRdB, txWaveform, nRxAnts)
    % Compute actual TX waveform power (per complex sample)
    sigPow = mean(abs(txWaveform(:)).^2);
    SNR = 10^(SNRdB/10);
    nVar = sigPow / SNR;
    noise = sqrt(nVar/2) * (randn(size(txWaveform)) + 1i*randn(size(txWaveform)));
end

function estChannelGrid = precodeChannelEstimate(estChannelGrid,W)

    K = size(estChannelGrid,1);
    L = size(estChannelGrid,2);
    R = size(estChannelGrid,3);   % number of TX antennas

    % Reshape to (K*L) x R  (preserve antenna dimension)
    estChannelGrid = reshape(estChannelGrid, K*L, R);

    % Apply precoding mapping
    % (K*L x R) * (R x Layers) -> (K*L x Layers)
    estChannelGrid = estChannelGrid * W;

    % Reshape back to K x L x Layers
    estChannelGrid = reshape(estChannelGrid, K, L, []);

end