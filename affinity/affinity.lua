--
-- The implementation for computing affinity between samples
--
-- > X: MxN matrix, where M is the number of samples and each has N-dims
-- > k: the number of nearest neighbors
--
-- < W: MxM matrix, whose elements are the affinities between samples
require "hdf5"
require("../agg_clustering_c/agg_clustering")
local agg_clustering = require("../agg_clustering/agg_clustering")
local knn = require 'knn'
local affinity = {}

function affinity.compute(X, k)
   -- print('X size: ', X:size())
   -- compute in batch
   local num_batches = X:size(1) / 10000
   local dists = torch.Tensor(X:size(1), k + 1):type(X:type())
   local indices = torch.IntTensor(X:size(1), k + 1)

   local dists, indices = knn.knn(X, X, k + 1)
   local sigma_square = torch.mean(dists[{{}, {2, k + 1}}])
   print("sigma: ", torch.sqrt(sigma_square))
   -- print(X:size())
   local nsamples = X:size(1)
   local ndims = X:size(2)
   local W = torch.FloatTensor(nsamples, nsamples):zero()
   local L = torch.LongTensor(nsamples, nsamples):zero()
   for i = 1, nsamples do
      for j = 2, k + 1 do
         nn_ind = indices[i][j]
         W[i][nn_ind] = torch.exp(-dists[i][j] / sigma_square)
         L[i][nn_ind] = 1
      end
   end
   return dists, indices, W, L, torch.sqrt(sigma_square)
end

function affinity.compute4cluster(X, W, Y_0, k, k_target)
   -- before perform agglomerative clustering, we find knn for clusters   
   local nclusters = #Y_0
   -- if k ~= nclusters then
   --  print("error!")
   -- end
   local dim = X:size(2)
   local X_clusters = torch.FloatTensor(nclusters, dim):zero()

   for i = 1, nclusters do
      -- print(Y_0[i])
      X_clusters:indexCopy(1, torch.LongTensor{i}, torch.mean(X:index(1, torch.LongTensor(Y_0[i])), 1))
   end

   local dists, indices = knn.knn(X_clusters, X_clusters, k)
   local NNs = torch.FloatTensor(nclusters, nclusters):zero()
   print(indices:size())
   for i = 1, nclusters do
      for j = 2, indices:size(2) do
         nn_ind = indices[i][j]
         --if nn_ind > nclusters or nn_ind < 1 then
           -- print("nn_ind", nn_ind)
         --end
         NNs[i][nn_ind] = 1
      end
   end
   
   -- to adapt to the c-interface, first convert table Y_0 to tensor Y_0_tensor
   local max_number = 0
   for i = 1, nclusters do
      if #(Y_0[i]) > max_number then
         max_number = #(Y_0[i])
      end
   end

   local Y_0_tensor = torch.FloatTensor(nclusters, max_number):zero()
   for i = 1, nclusters do
      for j = 1, #(Y_0[i]) do
         Y_0_tensor[i][j] = Y_0[i][j]
      end
   end

   
   timer = torch.Timer()   
   local A_unsym_0_c, A_sym_0_c = compute_CAff(W, NNs, Y_0_tensor)
   
   -- return A_unsym_0_c, A_sym_0_c, Y_0
   if k > 20 * k_target then 
   A_unsym_0_c = A_unsym_0_c:double()
   A_sym_0_c = A_sym_0_c:double()
   -- assert whether there are some self-contained clusters
   A_unsym_0_c_sum_r = torch.sum(A_unsym_0_c, 1)
   A_unsym_0_c_sum_c = torch.sum(A_unsym_0_c, 2)
   -- find the cluster ids whose affinities are both 0
   for i = 1, nclusters do
      if A_unsym_0_c_sum_r[1][i] == 0 and A_unsym_0_c_sum_c[i][1] == 0 then
         local idx_a = i
         local idx_b = 0
         for k = 1, indices:size(2) do            
            if indices[i][k] ~= i then
               idx_b = indices[i][k]
               break
            end
         end
         if idx_b > 0 then
            if idx_a > idx_b then
               print("merge ", idx_b, idx_a)            
               A_sym_0_c, A_unsym_0_c, Y_0 = agg_clustering.merge_two_clusters(W, A_sym_0_c, A_unsym_0_c, Y_0, idx_b, idx_a)
            else
               print("merge ", idx_a, idx_b)
               A_sym_0_c, A_unsym_0_c, Y_0 = agg_clustering.merge_two_clusters(W, A_sym_0_c, A_unsym_0_c, Y_0, idx_a, idx_b)
            end
            A_unsym_0_c_sum_r = torch.sum(A_unsym_0_c, 1)
            A_unsym_0_c_sum_c = torch.sum(A_unsym_0_c, 2)
         end
      end
   end
   end
   
   print('Time elapsed for computing cluster affinity: ' .. timer:time().real .. ' seconds')      
   return A_unsym_0_c, A_sym_0_c, Y_0   
end
return affinity
