#!/usr/bin/env python3
"""
COMSOL Js0 -> lambda physical mapping derivation

Key question: what Js0 produces a lambda that matches the theoretical adjoint?

Physical chain:
  Forward: E_total = E_bg + E_scat
  scatterer perturbation: delta_E_scat depends on delta_eps_r
  
  Adjoint: lambda satisfies the adjoint Maxwell equation
    curl(mu_r^-1 curl lambda) - k0^2 eps_r lambda = J_adjoint
  
  where J_adjoint is the source that produces lambda.

For gradient computation:
  dF/deps_r(v) = -k0^2 * Re(lambda(v) * E_fwd(v)) * dV(v)
  
  lambda must be the solution of the adjoint problem with source = dF/dE_scat

The adjoint source comes from:
  dF = sum_k <Delta_J(k), delta_J_obs(k)> / (norm * 6 * N_freq)
  
  delta_J_obs(k) = L(delta_E, delta_H) = integral of kernel * fields
  
  dF/dE_scat(s) and dF/dH_scat(s) are the adjoint sources

COMSOL surface sources:
  SurfaceCurrent Js0: weak form adds int_S Js0 . w dS
    This is equivalent to J_src in Maxwell eq
    Maxwell: curl(curl E) - k0^2 eps E = -i*omega*mu0 * J_src
    So Js0 directly maps to the source term

  SurfaceMagneticCurrentDensity Jms0:
    Introduces M_src in Maxwell: curl(E) = -i*omega*mu0*H - M_src
    In terms of E equation: appears as curl(M_src) or n_hat x M_src on surface
"""

import numpy as np

print("=" * 65)
print("  Js0 -> lambda physical mapping derivation")
print("=" * 65)

# Physical constants
c = 299792458; freq = 1e9; omega = 2*np.pi*freq; k0 = omega/c
eps0 = 8.854187817e-12; mu0 = 4*np.pi*1e-7; eta0 = np.sqrt(mu0/eps0)
omega_mu0 = omega * mu0

print(f"""
Physical constants:
  omega = {omega:.4e} rad/s
  mu0   = {mu0:.4e} H/m
  eps0  = {eps0:.4e} F/m
  eta0  = {eta0:.2f} Ohm
  omega*mu0 = {omega_mu0:.4e}

Maxwell equation (scattered field, bg=0):
  curl(curl E_s) - k0^2 * eps_r * E_s = source

  For SurfaceCurrent Js0 [A/m]:
    source_volume = -i*omega*mu0 * Js0 * delta_surface
    i.e. Js0 maps to Maxwell source via factor -i*omega*mu0
    
    So lambda = G * (-i*omega*mu0) * Js0  (where G = Green function)
    
    To get lambda_target, need:
      Js0 = lambda_target / (-i*omega*mu0) = i*lambda_target / (omega*mu0)
    
    BUT: the code convention is Js0 = -i*conj(Js) / (omega*mu0)
    This equals conj(Js) * (-i/(omega*mu0))
    
    If Js (the adjoint source from L^H) already = lambda_target (up to conj),
    then Js0 = -i*conj(Js)/(omega*mu0) is correct!

  For SurfaceMagneticCurrentDensity Jms0 [V/m]:
    Introduces M_src in Faraday: curl(E) = -i*omega*mu0*H - M_src
    
    In the E equation (taking curl of Faraday):
    curl(curl E) = -i*omega*mu0*curl(H) - curl(M_src)
    = -i*omega*mu0*(-i*omega*eps*E + J) - curl(M_src)
    = -omega^2*mu0*eps*E - i*omega*mu0*J - curl(M_src)
    
    So: curl(curl E) - k0^2*eps*E = -i*omega*mu0*J - curl(M_src)
    
    For surface M_src = Jms0 * delta_surface:
    curl(M_src) on surface = n_hat x Jms0 * delta_surface
    
    So Jms0 maps to source via n_hat x Jms0 (the surface curl)
    
    lambda = G * (-n_hat x Jms0)
    
    To get lambda_target from Jms0:
    Jms0 must be chosen so that -n_hat x Jms0 = lambda_source_target
""")

print("=" * 65)
print("  THE KEY INSIGHT")
print("=" * 65)
print(f"""
The adjoint source from L^H produces TWO quantities:
  Js_adj = L_H^H * dJ  (maps to H-space, relates to surface current)
  Ms_adj = L_E^H * dJ  (maps to E-space, relates to surface magnetic current)

In the forward lightcone_project:
  J_obs(k) = int [K_H * (n x H) + K_E * E/eta0] * phase * w dS

The physical surface quantities are:
  J_surface = n x H    (electric surface current, [A/m])
  M_surface = -n x E   (magnetic surface current, [V/m])

Adjoint mapping (what lambda should be driven by):
  The gradient g = -k0^2 * Re(lambda * E_fwd) * dV
  
  For g to be correct, lambda must satisfy:
    A^T * lambda = dF/dE_scat  (adjoint equation)
  
  where dF/dE_scat comes from:
    dF = sum_k conj(Delta_J(k)) . delta_J_obs(k) / (|J_obs|^2 * 6 * N_freq)
    
    delta_J_obs(k) = L(delta_E, delta_H) = int [K_H*(nx dH) + K_E*dE/eta0] phase w dS
    
    dF/dH(s) = sum_k conj(Delta_J(k)) * K_H^T * (nx)^T * phase_conj / norm
    dF/dE(s) = sum_k conj(Delta_J(k)) * K_E^T * phase_conj / (eta0 * norm)

Now, dF/dH(s) is the adjoint source for the H-equation.
But lambda solves the E-equation (curl curl E = ...).

The E-equation source from dF/dH is:
  The H-variation couples to E through Faraday: dH -> curl(dE)/(i*omega*mu0)
  
  In the weak form, dF/dH appears as a source for lambda through:
    int (dF/dH) . delta_H dV = int (dF/dH) . curl(delta_E)/(i*omega*mu0) dV
    = int curl(dF/dH)/(i*omega*mu0) . delta_E dV  (integration by parts)
    + surface term: int_S n x (dF/dH)/(i*omega*mu0) . delta_E dS

So the surface source for lambda from dF/dH is:
  Js0_from_H = n x (dF/dH) / (i*omega*mu0)
             = n x dF/dH * (-i) / (omega*mu0)
             = -i * n x dF/dH / (omega*mu0)

And from dF/dE:
  dF/dE couples directly (no curl needed):
  Jms0_from_E = -dF/dE   (direct source, note sign from M_src = -dF/dE)

Wait - this means the omega*mu0 scaling IS physically needed for Js0!
The code's /(omega*mu0) is correct for the Js path!

But the isolation test showed Js-only cos=0.047...

Let me check: is the issue that the conj convention double-counts?
""")

# The real question: does the code's -i*conj(Js)/(omega*mu0) match
# the physical requirement -i*n x (dF/dH) / (omega*mu0)?
#
# Js from build_adjoint = coeff_base * w(s) * K_J^T * dJ
# K_J^T * dJ = n x v_perp (verified correct)
#
# So Js = coeff_base * w(s) * n x v_perp
#
# Physical dF/dH(s) = sum_k conj(Delta_J(k)) * K_H^T * (n x)^T * phase_conj / norm
# = -sum_k conj(Delta_J(k)) * K_H^T * (n x) * phase_conj / norm  [(n x)^T = -(n x)]
# Wait, that's wrong. K_H already contains (n x). Let me be more careful.

# Forward: J_obs(i) = sum_s w(s) * phase(i,s) * [(k_i k_i^T - I)(n_s x) * H_s + ...]
# = M_H * H + M_E * E
# M_H(i,s) = w(s) * phase * (kk-I)(nx)
# 
# dF/dH(s) = sum_i conj(dJ(i)) * dJ_obs(i)/dH(s) / norm
#           = sum_i conj(dJ(i)) * M_H(i,s) / norm
#           = (M_H^T * conj(dJ))(s) / norm
#
# But M_H^T = conj(M_H^H) (since M_H is complex)
# Actually M_H^H = conj(M_H)^T, so M_H^T = conj(M_H^H)
# 
# dF/dH(s) = conj(M_H^H * dJ)(s) / norm = conj(Js_exact)(s) / norm
#
# where Js_exact = M_H^H * dJ (the exact adjoint)
#
# Physical Js0 = -i * n x (dF/dH) / (omega*mu0)
#              = -i * n x conj(Js_exact) / (norm * omega*mu0)
#              = -i * conj(n x Js_exact) / (norm * omega*mu0)  [n x is linear]
#              = conj(Js_exact) * (-i * (n x)) / (norm * omega*mu0)
#
# But code has Js0 = -i * conj(Js_code) / (omega*mu0)
# where Js_code = coeff_base * w * n x v_perp
#
# Js_exact = M_H^H * dJ = sum_k conj(phase) * w * [(kk-I)(nx)]^T * dJ
#          = w * sum_k conj(phase) * (nx)^T(kk-I)^T * dJ
#          = w * sum_k conj(phase) * (-(nx))(kk-I) * dJ
#          = -w * sum_k conj(phase) * (nx)(kk-I) * dJ
#
# Code's K_J^T * v = n x v_perp = n x (v - k(k.v))
# And we verified n x v_perp = M_H^H column (without conj(phase))
# Wait - Js_exact includes conj(phase) = exp(+ikr), and code's phase = exp(+ikr)
# So Js_exact should = w * sum_k exp(+ikr) * [-(nx)(kk-I)] * dJ
# = -w * sum_k exp(+ikr) * n x [(kk-I) dJ]
# But (kk-I)dJ = k(k.dJ) - dJ, and n x [k(k.dJ) - dJ] = n x k(k.dJ) - n x dJ
# Code's n x v_perp where v = dJ*phase: n x (dJ*phase - k(k.dJ*phase))
# = phase * [n x dJ - (k.dJ)(n x k)]
# This should match -[n x k(k.dJ) - n x dJ] = n x dJ - (k.dJ)(n x k)

# Hmm, these look the same! So Js_exact = code's Js_raw (up to conj)
# The sign should be correct.

# Let me check the conj more carefully.
# Js_exact = M_H^H * dJ uses dJ directly (not conj(dJ))
# But dF/dH = conj(M_H^H * dJ) / norm (from Wirtinger calculus)
# So the physical adjoint source for H is conj(Js_exact), not Js_exact!

# And Js0 = -i * n x conj(Js_exact) / (omega*mu0 * norm)
# = -i * conj(n x Js_exact) / (omega*mu0 * norm)
# 
# Code: Js0 = -i * conj(Js_code) / (omega*mu0)
# If Js_code = Js_exact, then Js0 = -i * conj(Js_exact) / (omega*mu0)
#
# Physical needs: Js0 = -i * conj(n x Js_exact) / (omega*mu0 * norm)
#                = -i * n x conj(Js_exact) / (omega*mu0 * norm)
#
# But code's Js_code already contains n x (from K_J^T = n x v_perp)
# So conj(Js_code) = conj(n x v_perp) = n x conj(v_perp)  [n is real]
#
# Wait! Js_code = coeff_base * w * (n x v_perp)
# conj(Js_code) = conj(coeff_base) * w * n x conj(v_perp)
# Js0 = -i * conj(coeff_base) * w * n x conj(v_perp) / (omega*mu0)
#
# Physical: Js0 = -i * n x conj(Js_exact) / (omega*mu0 * norm)
# where Js_exact = M_H^H * dJ (without coeff_base and norm)
#
# So need: conj(coeff_base) * w * conj(v_perp) = conj(Js_exact) / norm
# i.e. coeff_base * w * v_perp = Js_exact / norm  (taking conj of both sides)
#
# Js_exact = w * sum_k exp(+ikr) * [-(nx)(kk-I)] * dJ_k  (from M_H^H)
# Code: coeff_base * w * v_perp = coeff_base * w * (dJ_k * exp(+ikr) - k(k.dJ*exp(+ikr)))
#
# v_perp in code = Delta_J * phase - k * (k . (Delta_J * phase))
# = exp(+ikr) * [Delta_J - k(k.Delta_J)]
# = exp(+ikr) * (I - kk) * Delta_J
# = -exp(+ikr) * (kk - I) * Delta_J
#
# So coeff_base * w * v_perp = -coeff_base * w * exp(+ikr) * (kk-I) * Delta_J
#
# And Js_exact = -w * sum_k exp(+ikr) * (nx)(kk-I) * dJ
#
# These differ by (nx)! Js_exact has (nx)(kk-I), code has just (kk-I)
# The n x is applied SEPARATELY in code via K_J^T = n x v_perp
# So code's Js_raw = w * n x v_perp = w * n x [exp(+ikr)(I-kk)dJ]
# = w * n x [-exp(+ikr)(kk-I)dJ] = -w * n x [exp(+ikr)(kk-I)dJ]
# = -w * (nx)(kk-I) * exp(+ikr) * dJ
# = Js_exact  ✓
#
# So Js_code = coeff_base * Js_exact (they differ only by coeff_base scalar)
# This means Js0_code = -i * conj(coeff_base * Js_exact) / (omega*mu0)
# = -i * conj(coeff_base) * conj(Js_exact) / (omega*mu0)
#
# Physical Js0 = -i * n x conj(Js_exact) / (omega*mu0 * norm)
#
# But conj(Js_exact) already contains (nx) inside it!
# Js_exact = -w * (nx)(kk-I) * exp(+ikr) * dJ
# conj(Js_exact) = -w * (nx)(kk-I) * exp(-ikr) * conj(dJ)
# n x conj(Js_exact) = -w * (nx)(nx)(kk-I) * exp(-ikr) * conj(dJ)
# (nx)(nx) = n x (n x .) = n(n.) - . (BAC-CAB)
# So n x conj(Js_exact) involves DOUBLE cross product!

print("=" * 65)
print("  CRITICAL: Double cross product in Js0 mapping")
print("=" * 65)
print(f"""
Js_exact from M_H^H already contains (n x)(kk-I) factor.
Physical Js0 needs ANOTHER (n x) from the H->E coupling.

So: physical Js0 ~ n x conj(Js_exact)
  = n x [n x (...)] = (n.n^T - I)(...)  [double cross = projection]

Code's Js0 = -i*conj(Js_code)/(omega*mu0)
  where Js_code = coeff_base * n x v_perp (contains ONE n x)

The physical requirement has TWO n x operations:
  1. From K_J^T (adjoint of forward kernel) -> already in Js_code
  2. From H-field to E-field coupling in Maxwell weak form -> MISSING in code!

This is the root cause of Js-only cos=0.047!

The /(omega*mu0) in code was trying to compensate for the H->E coupling,
but it only handles the amplitude, not the DIRECTION (missing second n x).

FIX: The Js0 should be constructed to include the double cross product.
Since n x (n x v) = n(n.v) - v, the correct Js0 involves a PROJECTION,
not just the raw adjoint source.
""")

# Numerical verification: what does n x (n x v_perp) look like?
print("Numerical check: n x (n x v_perp) vs v_perp")
n_hat = np.array([0.25, 0.067, 0.9659])
n_hat = n_hat / np.linalg.norm(n_hat)
v = np.array([0.5+0.3j, 0.3-0.1j, 0.8+0.2j])

v_perp_k = v - np.array([0.348, 0, 0.9375]) * np.dot(np.array([0.348, 0, 0.9375]), v)
nx_vperp = np.cross(n_hat, v_perp_k)
nx_nx_vperp = np.cross(n_hat, nx_vperp)  # double cross = n(n.v_perp) - v_perp

# n x (n x v_perp) = n(n.v_perp) - v_perp = -(v_perp - n(n.v_perp)) = -v_perp_tangent_to_n
# But v_perp is already perpendicular to k, not to n!
# v_perp = v - k(k.v), which is perpendicular to k but NOT necessarily to n

ndot_vp = np.dot(n_hat, v_perp_k)
proj_check = n_hat * ndot_vp - v_perp_k

print(f"  v_perp (perp to k)      = {v_perp_k}")
print(f"  n x v_perp              = {nx_vperp}")
print(f"  n x (n x v_perp)        = {nx_nx_vperp}")
print(f"  n(n.v_perp) - v_perp    = {proj_check}")
print(f"  Match? {np.allclose(nx_nx_vperp, proj_check)}")
print(f"  n.v_perp = {ndot_vp:.6f} (NOT zero! v_perp is perp to k, not n)")

# So n x (n x v_perp) is NOT simply -v_perp
# It's n(n.v_perp) - v_perp, which projects out the n-component

# For the CORRECT Js0, we need:
# Js0_correct = -i * conj(coeff_base) / (omega*mu0) * [n x conj(n x v_perp * phase)]
# This is NOT what the code computes!

print(f"\n  Conclusion: Js0 needs double cross product n x (n x .)")
print(f"  Code only has single n x in K_J^T")
print(f"  The /(omega*mu0) compensates amplitude but not direction")
print(f"  This explains why Ms-only works (no extra n x needed for E-coupling)")
print(f"  but Js-only fails (missing second n x for H->E mapping)")
