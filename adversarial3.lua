require 'torch'
require 'optim'
require 'pl'
require 'interruptable_optimizers'
require 'image'

local adversarial = {}

-- this variable will save the accuracy values of D
adversarial.accs = {}

-- function to calculate the mean of a list of numbers
function adversarial.mean(t)
    local sum = 0
    local count = 0

    for k,v in pairs(t) do
        if type(v) == 'number' then
            sum = sum + v
            count = count + 1
        end
    end

    return (sum / count)
end

-- main training function
function adversarial.train(trainData, maxAccuracyD, accsInterval)
    EPOCH = EPOCH or 1
    local N_epoch = OPT.N_epoch
    if N_epoch <= 0 then
        N_epoch = trainData:size()
    end
    local dataBatchSize = OPT.batchSize / 2 -- size of a half-batch for D or G
    local time = sys.clock()
    
    -- variables to track D's accuracy
    local lastAccuracyD = 0.0
    local doTrainD = true
    local countTrainedD = 0
    local countNotTrainedD = 0
    local count_lr_increased_D = 0
    local count_lr_decreased_D = 0
    samples = nil

    local batchIdx = 0

    -- do one epoch
    -- While this function is structured like one that picks example batches in consecutive order,
    -- in reality the examples (per batch) will be picked randomly
    print(string.format("<trainer> Epoch #%d [batchSize = %d]", EPOCH, OPT.batchSize))
    for t = 1,N_epoch,dataBatchSize do
        -- size of this batch, will usually be dataBatchSize but can be lower at the end
        local thisBatchSize = math.min(OPT.batchSize, N_epoch - t + 1)
        
        -- Inputs for D, either original or generated images
        local inputs = torch.Tensor(thisBatchSize, IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
        
        -- target y-values
        local targets = torch.Tensor(thisBatchSize)
        
        -- tensor to use for noise for G
        local noiseInputs = torch.Tensor(thisBatchSize, OPT.noiseDim)
        
        -- this script currently can't handle small sized batches
        if thisBatchSize < 4 then
            print(string.format("[INFO] skipping batch at t=%d, because its size is less than 4", t))
            break
        end

        ----------------------------------------------------------------------
        -- create closure to evaluate f(X) and df/dX of D
        local fevalD = function(x)
            collectgarbage()
            local confusion_batch_D = optim.ConfusionMatrix(CLASSES)
            confusion_batch_D:zero()

            if x ~= PARAMETERS_D then -- get new parameters
                PARAMETERS_D:copy(x)
            end

            GRAD_PARAMETERS_D:zero() -- reset gradients

            --  forward pass
            local outputs = MODEL_D:forward(inputs)
            local f = CRITERION:forward(outputs, targets)

            -- backward pass 
            local df_do = CRITERION:backward(outputs, targets)
            MODEL_D:backward(inputs, df_do)

            -- penalties (L1 and L2):
            if OPT.D_L1 ~= 0 or OPT.D_L2 ~= 0 then
                -- Loss:
                f = f + OPT.D_L1 * torch.norm(PARAMETERS_D, 1)
                f = f + OPT.D_L2 * torch.norm(PARAMETERS_D, 2)^2/2
                -- Gradients:
                GRAD_PARAMETERS_D:add(torch.sign(PARAMETERS_D):mul(OPT.D_L1) + PARAMETERS_D:clone():mul(OPT.D_L2) )
            end

            -- update confusion (add 1 since targets are binary)
            for i = 1,thisBatchSize do
                local c
                if outputs[i][1] > 0.5 then c = 2 else c = 1 end
                CONFUSION:add(c, targets[i]+1)
                confusion_batch_D:add(c, targets[i]+1)
                --print("outputs[i][1]:" .. (outputs[i][1]) .. ", c: " .. c ..", targets[i]+1:" .. (targets[i]+1))
            end

            -- Clamp D's gradients
            -- This helps a bit against D suddenly giving up (only outputting y=1 or y=0)
            if OPT.D_clamp ~= 0 then
                GRAD_PARAMETERS_D:clamp((-1)*OPT.D_clamp, OPT.D_clamp)
            end

            -- Calculate accuracy of D on this batch
            confusion_batch_D:updateValids()
            local tV = confusion_batch_D.totalValid
            
            -- this keeps the accuracy of D at around 80%
            --[[
            if EPOCH > 1 then
                if tV > 0.95 then
                    OPTSTATE.adam.D.learningRate = OPTSTATE.adam.D.learningRate * 0.98
                    count_lr_decreased_D = count_lr_decreased_D + 1
                    --if EPOCH > 1 then
                    --    OPTSTATE.adam.G.learningRate = OPTSTATE.adam.G.learningRate * 1.001
                    --end
                elseif tV < 0.90 then
                    OPTSTATE.adam.D.learningRate = OPTSTATE.adam.D.learningRate * 1.02
                    count_lr_increased_D = count_lr_increased_D + 1
                    --if EPOCH > 1 then
                    --    OPTSTATE.adam.G.learningRate = OPTSTATE.adam.G.learningRate * 0.999
                    --end
                else
                    OPTSTATE.adam.D.learningRate = OPTSTATE.adam.D.learningRate * 1.001
                end
            end
            
            OPTSTATE.adam.D.learningRate = math.max(0.00001, OPTSTATE.adam.D.learningRate)
            OPTSTATE.adam.D.learningRate = math.min(0.001, OPTSTATE.adam.D.learningRate)
            --]]
            
            -- Add this batch's accuracy to the history of D's accuracies
            -- Also, keep that history to a fixed size
            adversarial.accs[#adversarial.accs+1] = tV
            if #adversarial.accs > accsInterval then
                table.remove(adversarial.accs, 1)
            end
            
            -- Mean accuracy of D over the last couple of batches
            local accAvg = adversarial.mean(adversarial.accs)
            
            -- We will only train D if its mean accuracy over the last couple of batches
            -- was below the defined maximum (maxAccuracyD). This protects a bit against
            -- G generating garbage.
            doTrainD = (accAvg < maxAccuracyD)
            lastAccuracyD = tV
            if doTrainD then
                countTrainedD = countTrainedD + 1
                return f,GRAD_PARAMETERS_D
            else
                countNotTrainedD = countNotTrainedD + 1
                
                -- The interruptable* Optimizers dont train when false is returned
                -- Maybe that would be equivalent to just returning 0 for all gradients?
                return false,false
            end
        end

        ----------------------------------------------------------------------
        -- create closure to evaluate f(X) and df/dX of generator 
        local fevalG_on_D = function(x)
            collectgarbage()
            if x ~= PARAMETERS_G then -- get new parameters
                PARAMETERS_G:copy(x)
            end

            GRAD_PARAMETERS_G:zero() -- reset gradients

            -- forward pass
            --local samples
            local samplesAE
            if MODEL_AE then
                samplesAE = MODEL_AE:forward(noiseInputs)
                samples = MODEL_G:forward(samplesAE)
            else
                samples = NN_UTILS.createImagesFromNoise(noiseInputs, false, true)
            end
            local outputs = MODEL_D:forward(samples)
            local f = CRITERION:forward(outputs, targets)

            --  backward pass
            local df_samples = CRITERION:backward(outputs, targets)
            MODEL_D:backward(samples, df_samples)
            local df_do = MODEL_D.modules[1].gradInput
            if MODEL_AE then
                MODEL_G:backward(samplesAE, df_do)
            else
                MODEL_G:backward(noiseInputs, df_do)
            end

            -- penalties (L1 and L2):
            if OPT.G_L1 ~= 0 or OPT.G_L2 ~= 0 then
                -- Loss:
                f = f + OPT.G_L1 * torch.norm(PARAMETERS_G, 1)
                f = f + OPT.G_L2 * torch.norm(PARAMETERS_G, 2)^2/2
                -- Gradients:
                GRAD_PARAMETERS_G:add(torch.sign(PARAMETERS_G):mul(OPT.G_L1) + PARAMETERS_G:clone():mul(OPT.G_L2))
            end

            if OPT.G_clamp ~= 0 then
                GRAD_PARAMETERS_G:clamp((-1)*OPT.G_clamp, OPT.G_clamp)
            end

            --GRAD_PARAMETERS_G:zero()
            return f,GRAD_PARAMETERS_G
        end
        
        -- create closure to evaluate f(X) and df/dX of generator 
        local fevalG2_on_D = function(x)
            collectgarbage()
            if x ~= PARAMETERS_G2 then -- get new parameters
                PARAMETERS_G2:copy(x)
            end

            GRAD_PARAMETERS_G2:zero() -- reset gradients

            -- forward pass
            --local samples
            local samples = MODEL_G2:forward(noiseInputs)
            local outputs = MODEL_D:forward(samples)
            local f = CRITERION:forward(outputs, targets)
            --print(MODEL_G2.modules[1].modules[5])
            --local G1_output = MODEL_G2.modules[1].modules[5].output
            --local f = CRITERION_G2:forward({outputs, G1_output}, {targets, G1_output})

            --  backward pass
            local df_samples = CRITERION:backward(outputs, targets)
            --local df_samples = CRITERION_G2:backward({outputs, G1_output}, {targets, G1_output})
            MODEL_D:backward(samples, df_samples)
            local df_do = MODEL_D.modules[1].gradInput
            
            --local G1_output = MODEL_G2.modules[1].modules[2].modules[5].output
            local G1_output = MODEL_G2.modules[1].modules[3].output
            CRITERION_G2_DIFF:forward(samples, G1_output)
            local df_do_diff = CRITERION_G2_DIFF:backward(samples, G1_output)
            
            --df_do:mul(0.0025)
            df_do:mul(0.01)
            local df_both = torch.add(df_do_diff, df_do)
            MODEL_G2:backward(noiseInputs, df_both)
            --MODEL_G2:backward(noiseInputs, df_do)

            local g2l1 = 0e-4
            local g2l2 = 0e-4
            -- penalties (L1 and L2):
            if OPT.G_L1 ~= 0 or OPT.G_L2 ~= 0 then
                -- Loss:
                f = f + OPT.G_L1 * torch.norm(PARAMETERS_G2, 1)
                f = f + OPT.G_L2 * torch.norm(PARAMETERS_G2, 2)^2/2
                -- Gradients:
                GRAD_PARAMETERS_G2:add(torch.sign(PARAMETERS_G2):mul(g2l1) + PARAMETERS_G2:clone():mul(g2l2))
            end

            if OPT.G_clamp ~= 0 then
                GRAD_PARAMETERS_G2:clamp((-1)*OPT.G_clamp, OPT.G_clamp)
            end

            --GRAD_PARAMETERS_G2:mul(0.5)

            return f,GRAD_PARAMETERS_G2
        end
        
        -- create closure to evaluate f(X) and df/dX of generator 
        local fevalG3_on_D = function(x)
            collectgarbage()
            if x ~= PARAMETERS_G3 then -- get new parameters
                PARAMETERS_G3:copy(x)
            end

            GRAD_PARAMETERS_G3:zero() -- reset gradients

            -- forward pass
            --local samples
            local samples = MODEL_G3:forward(noiseInputs)
            local outputs = MODEL_D:forward(samples)
            local f = CRITERION:forward(outputs, targets)
            --print(MODEL_G2.modules[1].modules[5])
            --local G1_output = MODEL_G2.modules[1].modules[5].output
            --local f = CRITERION_G2:forward({outputs, G1_output}, {targets, G1_output})

            --  backward pass
            local df_samples = CRITERION:backward(outputs, targets)
            --local df_samples = CRITERION_G2:backward({outputs, G1_output}, {targets, G1_output})
            MODEL_D:backward(samples, df_samples)
            local df_do = MODEL_D.modules[1].gradInput
            
            --local G1_output = MODEL_G2.modules[1].modules[2].modules[5].output
            local G2_output = MODEL_G3.modules[1].modules[4].output
            CRITERION_G3_DIFF:forward(samples, G2_output)
            local df_do_diff = CRITERION_G3_DIFF:backward(samples, G2_output)
            
            df_do:mul(0.01)
            local df_both = torch.add(df_do_diff, df_do)
            MODEL_G3:backward(noiseInputs, df_both)
            --MODEL_G2:backward(noiseInputs, df_do)

            -- penalties (L1 and L2):
            if OPT.G_L1 ~= 0 or OPT.G_L2 ~= 0 then
                -- Loss:
                f = f + OPT.G_L1 * torch.norm(PARAMETERS_G3, 1)
                f = f + OPT.G_L2 * torch.norm(PARAMETERS_G3, 2)^2/2
                -- Gradients:
                GRAD_PARAMETERS_G3:add(torch.sign(PARAMETERS_G3):mul(OPT.G_L1) + PARAMETERS_G3:clone():mul(OPT.G_L2))
            end

            if OPT.G_clamp ~= 0 then
                GRAD_PARAMETERS_G3:clamp((-1)*OPT.G_clamp, OPT.G_clamp)
            end

            --GRAD_PARAMETERS_G2:mul(0.5)

            return f,GRAD_PARAMETERS_G3
        end
        ------------------- end of eval functions ---------------------------

        ----------------------------------------------------------------------
        -- (1) Update D network: maximize log(D(x)) + log(1 - D(G(z)))
        -- Get half a minibatch of real, half fake
        for k=1, OPT.D_iterations do
            -- (1.1) Real data 
            local inputIdx = 1
            local realDataSize = thisBatchSize / 2
            for i = 1, realDataSize do
                local randomIdx = math.random(trainData:size())
                inputs[inputIdx] = trainData[randomIdx]:clone()
                targets[inputIdx] = Y_NOT_GENERATOR
                inputIdx = inputIdx + 1
            end

            -- (1.2) Sampled data
            local rnd = math.random()
            local samples
            if rnd < 0.5 then
                samples = NN_UTILS.createImages(realDataSize, false)
            elseif rnd < 0.8 then
                local noise = NN_UTILS.createNoiseInputs(realDataSize)
                samples = MODEL_G2:forward(noise)
            else
                local noise = NN_UTILS.createNoiseInputs(realDataSize)
                samples = MODEL_G3:forward(noise)
            end
            for i = 1, realDataSize do
                inputs[inputIdx] = samples[i]:clone()
                targets[inputIdx] = Y_GENERATOR
                inputIdx = inputIdx + 1
            end
            
            if OPT.D_optmethod == "sgd" then
                interruptableSgd(fevalD, PARAMETERS_D, OPTSTATE.sgd.D)
            elseif OPT.D_optmethod == "adagrad" then
                interruptableAdagrad(fevalD, PARAMETERS_D, OPTSTATE.adagrad.D)
            elseif OPT.D_optmethod == "adam" then
                interruptableAdam(fevalD, PARAMETERS_D, OPTSTATE.adam.D)
            else
                print("[Warning] Unknown optimizer method chosen for D.")
            end
        end -- end for K

        ---------------------------------------------------------------------
        -- (1) Update D network: maximize log(D(x)) + log(1 - D(G(z)))
        -- Get half a minibatch of real, half fake
        -- The fake images are synthetic
        --[[
        for k=1, OPT.D_iterations do
            -- (1.1) Real data 
            local inputIdx = 1
            local realDataSize = thisBatchSize / 2
            for i = 1, realDataSize do
                local randomIdx = math.random(trainData:size())
                inputs[inputIdx] = trainData[randomIdx]:clone()
                targets[inputIdx] = Y_NOT_GENERATOR
                inputIdx = inputIdx + 1
            end
            
            -- (1.2) Sampled data
            local samplesG = NN_UTILS.createImages(realDataSize, false)
            local samplesD = MODEL_D:forward(samplesG)
            local convLayer = MODEL_D:get(1)
            local convOutput = convLayer.output
            for i = 1, realDataSize do
                local randomIdx = math.random(convOutput:size(2))
                for channel=1, IMG_DIMENSIONS[1] do
                    inputs[inputIdx][channel] = convOutput[i][randomIdx]:clone()
                end
                targets[inputIdx] = Y_GENERATOR
                inputIdx = inputIdx + 1
                if t == 1 and i == 1 then
                    image.display(inputs[inputIdx-1])
                end
            end
            
            if OPT.D_optmethod == "sgd" then
                interruptableSgd(fevalD, PARAMETERS_D, OPTSTATE.sgd.D)
            elseif OPT.D_optmethod == "adagrad" then
                interruptableAdagrad(fevalD, PARAMETERS_D, OPTSTATE.adagrad.D)
            elseif OPT.D_optmethod == "adam" then
                interruptableAdam(fevalD, PARAMETERS_D, OPTSTATE.adam.D)
            else
                print("[Warning] Unknown optimizer method chosen for D.")
            end
        end
        --]]

        ----------------------------------------------------------------------
        -- (2) Update G network: maximize log(D(G(z)))
        for k=1, OPT.G_iterations do
            noiseInputs = NN_UTILS.createNoiseInputs(noiseInputs:size(1))
            targets:fill(Y_NOT_GENERATOR)
            
            if OPT.G_optmethod == "sgd" then
                interruptableSgd(fevalG_on_D, PARAMETERS_G, OPTSTATE.sgd.G)
            elseif OPT.G_optmethod == "adagrad" then
                interruptableAdagrad(fevalG_on_D, PARAMETERS_G, OPTSTATE.adagrad.G)
            elseif OPT.G_optmethod == "adam" then
                interruptableAdam(fevalG_on_D, PARAMETERS_G, OPTSTATE.adam.G)
            else
                print("[Warning] Unknown optimizer method chosen for G.")
            end
        end
        
        if EPOCH > 0 then
            for k=1, OPT.G_iterations do
                noiseInputs = NN_UTILS.createNoiseInputs(noiseInputs:size(1))
                targets:fill(Y_NOT_GENERATOR)
                
                --interruptableAdagrad(fevalG2_on_D, PARAMETERS_G2, OPTSTATE.adagrad.G2)
                
                if OPT.G_optmethod == "sgd" then
                    interruptableSgd(fevalG2_on_D, PARAMETERS_G2, OPTSTATE.sgd.G2)
                elseif OPT.G_optmethod == "adagrad" then
                    interruptableAdagrad(fevalG2_on_D, PARAMETERS_G2, OPTSTATE.adagrad.G2)
                elseif OPT.G_optmethod == "adam" then
                    interruptableAdam(fevalG2_on_D, PARAMETERS_G2, OPTSTATE.adam.G2)
                else
                    print("[Warning] Unknown optimizer method chosen for G2.")
                end
                
            end
        end
        
        if EPOCH > 0 then
            for k=1, OPT.G_iterations do
                noiseInputs = NN_UTILS.createNoiseInputs(noiseInputs:size(1))
                targets:fill(Y_NOT_GENERATOR)
                
                --interruptableAdagrad(fevalG3_on_D, PARAMETERS_G3, OPTSTATE.adagrad.G3)
                
                if OPT.G_optmethod == "sgd" then
                    interruptableSgd(fevalG3_on_D, PARAMETERS_G3, OPTSTATE.sgd.G3)
                elseif OPT.G_optmethod == "adagrad" then
                    interruptableAdagrad(fevalG3_on_D, PARAMETERS_G3, OPTSTATE.adagrad.G3)
                elseif OPT.G_optmethod == "adam" then
                    interruptableAdam(fevalG3_on_D, PARAMETERS_G3, OPTSTATE.adam.G3)
                else
                    print("[Warning] Unknown optimizer method chosen for G3.")
                end
            end
        end

        batchIdx = batchIdx + 1
        -- display progress
        xlua.progress(t+thisBatchSize, N_epoch)
        
        if OPT.weightsVisFreq > 0 and batchIdx % OPT.weightsVisFreq == 0 then
            adversarial.visualizeNetwork(MODEL_D)
        end
    end -- end for loop over dataset

    -- time taken
    time = sys.clock() - time
    print(string.format("<trainer> time required for this epoch = %d s", time))
    print(string.format("<trainer> time to learn 1 sample = %f ms", 1000 * time/N_epoch))
    print(string.format("<trainer> trained D %d of %d times.", countTrainedD, countTrainedD + countNotTrainedD))
    --print(string.format("<trainer> adam learning rate D:%.5f | G:%.5f", OPTSTATE.adam.D.learningRate, OPTSTATE.adam.G.learningRate))
    --print(string.format("<trainer> adam learning rate D increased:%d decreased:%d", count_lr_increased_D, count_lr_decreased_D))

    -- print confusion matrix
    print("Confusion of D:")
    print(CONFUSION)
    local tV = CONFUSION.totalValid
    CONFUSION:zero()

    return tV
end

-- Show the activity of a network in windows (i.e. windows full of blinking dots).
-- The windows will automatically be reused.
-- Only the activity of the layer types nn.SpatialConvolution and nn.Linear will be shown.
-- Linear layers must have a minimum size to be shown (i.e. to not show the tiny output layers).
--
-- NOTE: This function can only visualize one network proberly while the program runs.
-- I.e. you can't call this function to show network A and then another time to show network B,
-- because the function tries to reuse windows and that will not work correctly in such a case.
--
-- @param net The network to visualize.
-- @param minOutputs Minimum (output) size of a linear layer to be shown.
function adversarial.visualizeNetwork(net, minOutputs)
    if minOutputs == nil then
        minOutputs = 150
    end
    
    -- (Global) Table to save the window ids in, so that we can reuse them between calls.
    netvis_windows = netvis_windows or {}
    
    local modules = net:listModules()
    local winIdx = 1
    -- last module seems to have no output?
    for i=1,(#modules-1) do
        local t = torch.type(modules[i])
        local showTensor = nil
        -- This function only shows the activity of 2d convolutions and linear layers
        if t == 'nn.SpatialConvolution' then
            showTensor = modules[i].output[1]
        elseif t == 'nn.Linear' then
            local output = modules[i].output
            local shape = output:size()
            local nbValues = shape[2]
            
            if nbValues >= minOutputs and nbValues >= minOutputs then
                local nbRows = torch.floor(torch.sqrt(nbValues))
                while nbValues % nbRows ~= 0 and nbRows < nbValues do
                    nbRows = nbRows + 1
                end
                
                if nbRows >= nbValues then
                    showTensor = nil
                else
                    showTensor = output[1]:view(nbRows, nbValues / nbRows)
                end
            end
        end
        
        -- Show the layer outputs in a window
        -- Note that windows are reused if possible
        if showTensor ~= nil then
            netvis_windows[winIdx] = image.display{
                image=showTensor, zoom=1, nrow=32,
                min=-1, max=1,
                win=netvis_windows[winIdx], legend=t .. ' (#' .. i .. ')',
                padding=1
            }
            winIdx = winIdx + 1
        end
    end
end

return adversarial
