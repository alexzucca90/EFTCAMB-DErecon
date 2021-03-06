!----------------------------------------------------------------------------------------
!
! This file is part of EFTCAMB.
!
! Copyright (C) 2013-2017 by the EFTCAMB authors
!
! The EFTCAMB code is free software;
! You can use it, redistribute it, and/or modify it under the terms
! of the GNU General Public License as published by the Free Software Foundation;
! either version 3 of the License, or (at your option) any later version.
! The full text of the license can be found in the file eftcamb/LICENSE at
! the top level of the EFTCAMB distribution.
!
!----------------------------------------------------------------------------------------

!> @file stability_sampler.F90
!! This application takes care of doing 1D and 2D parameter space sampling enforcing
!! EFTCAMB viability conditions, as specified by a parameter file.
!! Part of this file is taken from the inidriver file of CAMB.

! hardcoded options:
module hardcoded_options

    use precision

    real(dl), parameter :: log_sampling_value = 1.d-4 ! the value at which the sampler switches from linear to log sampling
    real(dl), parameter :: log_sampling_min   = 1.d-8 ! the assumed minimum log sampling value

end module hardcoded_options

! the program itself:
program stability_sampler

    use IniFile
    use CAMB
    use LambdaGeneral
    use Lensing
    use AMLUtils
    use Transfer
    use constants
    use Bispectrum
    use CAMBmain
    use omp_lib
#ifdef NAGF95
    use F90_UNIX
#endif
    use hardcoded_options

    implicit none

    Type(CAMBparams) P

    character(LEN=Ini_max_string_len) numstr, VectorFileName, &
        InputFile, ScalarFileName, TensorFileName, TotalFileName, LensedFileName,&
        LensedTotFileName, LensPotentialFileName,ScalarCovFileName, benchmark_buffer
    integer i, benchmark_count
    character(LEN=Ini_max_string_len) TransferFileNames(max_transfer_redshifts), &
        MatterPowerFileNames(max_transfer_redshifts), outroot, version_check
    real(dl) output_factor, nmassive
    real(dl) t1, t2, param_1_max, param_1_min, param_2_max, param_2_min
    integer param_number
    logical do_log_sampling_param_1, do_log_sampling_param_2

#ifdef WRITE_FITS
    character(LEN=Ini_max_string_len) FITSfilename
#endif

    logical bad

    InputFile = ''
    if (GetParamCount() /= 0)  InputFile = GetParam(1)
    if (InputFile == '') stop 'No parameter input file'

    call Ini_Open(InputFile, 1, bad, .false.)
    if (bad) stop 'Error opening parameter file'

    Ini_fail_on_not_found = .false.

    outroot = Ini_Read_String('output_root')
    if (outroot /= '') outroot = trim(outroot) // '_'

    highL_unlensed_cl_template = Ini_Read_String_Default('highL_unlensed_cl_template',highL_unlensed_cl_template)

    call CAMB_SetDefParams(P)

    P%WantScalars = Ini_Read_Logical('get_scalar_cls')
    P%WantVectors = Ini_Read_Logical('get_vector_cls',.false.)
    P%WantTensors = Ini_Read_Logical('get_tensor_cls',.false.)

    P%OutputNormalization=outNone
    output_factor = Ini_Read_Double('CMB_outputscale',1.d0)

    P%WantCls= P%WantScalars .or. P%WantTensors .or. P%WantVectors

    P%PK_WantTransfer=Ini_Read_Logical('get_transfer')

    AccuracyBoost  = Ini_Read_Double('accuracy_boost',AccuracyBoost)
    lAccuracyBoost = Ini_Read_Real('l_accuracy_boost',lAccuracyBoost)
    HighAccuracyDefault = Ini_Read_Logical('high_accuracy_default',HighAccuracyDefault)

    P%NonLinear = Ini_Read_Int('do_nonlinear',NonLinear_none)

    P%DoLensing = .false.
    if (P%WantCls) then
        if (P%WantScalars  .or. P%WantVectors) then
            P%Max_l = Ini_Read_Int('l_max_scalar')
            P%Max_eta_k = Ini_Read_Double('k_eta_max_scalar',P%Max_l*2._dl)
            if (P%WantScalars) then
                P%DoLensing = Ini_Read_Logical('do_lensing',.false.)
                if (P%DoLensing) lensing_method = Ini_Read_Int('lensing_method',1)
            end if
            if (P%WantVectors) then
                if (P%WantScalars .or. P%WantTensors) stop 'Must generate vector modes on their own'
                i = Ini_Read_Int('vector_mode')
                if (i==0) then
                    vec_sig0 = 1
                    Magnetic = 0
                else if (i==1) then
                    Magnetic = -1
                    vec_sig0 = 0
                else
                    stop 'vector_mode must be 0 (regular) or 1 (magnetic)'
                end if
            end if
        end if

        if (P%WantTensors) then
            P%Max_l_tensor = Ini_Read_Int('l_max_tensor')
            P%Max_eta_k_tensor =  Ini_Read_Double('k_eta_max_tensor',Max(500._dl,P%Max_l_tensor*2._dl))
        end if
    endif

    !  Read initial parameters.

    call DarkEnergy_ReadParams(DefIni)

    P%h0     = Ini_Read_Double('hubble')

    if (Ini_Read_Logical('use_physical',.false.)) then
        P%omegab = Ini_Read_Double('ombh2')/(P%H0/100)**2
        P%omegac = Ini_Read_Double('omch2')/(P%H0/100)**2
        P%omegan = Ini_Read_Double('omnuh2')/(P%H0/100)**2
        P%omegav = 1- Ini_Read_Double('omk') - P%omegab-P%omegac - P%omegan
    else
        P%omegab = Ini_Read_Double('omega_baryon')
        P%omegac = Ini_Read_Double('omega_cdm')
        P%omegav = Ini_Read_Double('omega_lambda')
        P%omegan = Ini_Read_Double('omega_neutrino')
    end if

    P%tcmb   = Ini_Read_Double('temp_cmb',COBE_CMBTemp)
    P%yhe    = Ini_Read_Double('helium_fraction',0.24_dl)
    P%Num_Nu_massless  = Ini_Read_Double('massless_neutrinos')

    ! EFTCAMB MOD START: read and allocate EFTCAMB
    ! read the EFTCAMB model selection flags:
    call P%EFTCAMB%EFTCAMB_init_from_file( DefIni )
    if ( P%EFTCAMB%EFTFlag /= 0 ) then
        ! print the EFTCAMB header:
        call P%EFTCAMB%EFTCAMB_print_header()
        ! initialize the output root name:
        P%EFTCAMB%outroot = TRIM( outroot )
        ! initialize the model from file:
        call P%EFTCAMB%EFTCAMB_init_model_from_file( DefIni )
        ! print feedback:
        call P%EFTCAMB%EFTCAMB_print_model_feedback( print_params=.False. )
    end if
    ! EFTCAMB MOD END.

    P%Nu_mass_eigenstates = Ini_Read_Int('nu_mass_eigenstates',1)
    if (P%Nu_mass_eigenstates > max_nu) stop 'too many mass eigenstates'

    numstr = Ini_Read_String('massive_neutrinos')
    read(numstr, *) nmassive
    if (abs(nmassive-nint(nmassive))>1e-6) stop 'massive_neutrinos should now be integer (or integer array)'
    read(numstr,*, end=100, err=100) P%Nu_Mass_numbers(1:P%Nu_mass_eigenstates)
    P%Num_Nu_massive = sum(P%Nu_Mass_numbers(1:P%Nu_mass_eigenstates))

    if (P%Num_Nu_massive>0) then
        P%share_delta_neff = Ini_Read_Logical('share_delta_neff', .true.)
        numstr = Ini_Read_String('nu_mass_degeneracies')
        if (P%share_delta_neff) then
            if (numstr/='') write (*,*) 'WARNING: nu_mass_degeneracies ignored when share_delta_neff'
        else
            if (numstr=='') stop 'must give degeneracies for each eigenstate if share_delta_neff=F'
            read(numstr,*) P%Nu_mass_degeneracies(1:P%Nu_mass_eigenstates)
        end if
        numstr = Ini_Read_String('nu_mass_fractions')
        if (numstr=='') then
            if (P%Nu_mass_eigenstates >1) stop 'must give nu_mass_fractions for the eigenstates'
            P%Nu_mass_fractions(1)=1
        else
            read(numstr,*) P%Nu_mass_fractions(1:P%Nu_mass_eigenstates)
        end if
    end if

    !JD 08/13 begin changes for nonlinear lensing of CMB + LSS compatibility
    !P%Transfer%redshifts -> P%Transfer%PK_redshifts and P%Transfer%num_redshifts -> P%Transfer%PK_num_redshifts
    !in the P%WantTransfer loop.
    if (((P%NonLinear==NonLinear_lens .or. P%NonLinear==NonLinear_both) .and. P%DoLensing) &
        .or. P%PK_WantTransfer) then
        P%Transfer%high_precision=  Ini_Read_Logical('transfer_high_precision',.false.)
    else
        P%transfer%high_precision = .false.
    endif

    if (P%PK_WantTransfer)  then
        P%WantTransfer  = .true.
        P%transfer%kmax          =  Ini_Read_Double('transfer_kmax')
        P%transfer%k_per_logint  =  Ini_Read_Int('transfer_k_per_logint')
        P%transfer%PK_num_redshifts =  Ini_Read_Int('transfer_num_redshifts')

        transfer_interp_matterpower = Ini_Read_Logical('transfer_interp_matterpower ', transfer_interp_matterpower)
        transfer_power_var = Ini_read_int('transfer_power_var',transfer_power_var)
        if (P%transfer%PK_num_redshifts > max_transfer_redshifts) stop 'Too many redshifts'
        do i=1, P%transfer%PK_num_redshifts
            P%transfer%PK_redshifts(i)  = Ini_Read_Double_Array('transfer_redshift',i,0._dl)
            transferFileNames(i)     = Ini_Read_String_Array('transfer_filename',i)
            MatterPowerFilenames(i)  = Ini_Read_String_Array('transfer_matterpower',i)
            if (TransferFileNames(i) == '') then
                TransferFileNames(i) =  trim(numcat('transfer_',i))//'.dat'
            end if
            if (MatterPowerFilenames(i) == '') then
                MatterPowerFilenames(i) =  trim(numcat('matterpower_',i))//'.dat'
            end if
            if (TransferFileNames(i)/= '') &
                TransferFileNames(i) = trim(outroot)//TransferFileNames(i)
            if (MatterPowerFilenames(i) /= '') &
                MatterPowerFilenames(i)=trim(outroot)//MatterPowerFilenames(i)
        end do
    else
        P%Transfer%PK_num_redshifts = 1
        P%Transfer%PK_redshifts = 0
    end if

    if ((P%NonLinear==NonLinear_lens .or. P%NonLinear==NonLinear_both) .and. P%DoLensing) then
        P%WantTransfer  = .true.
        call Transfer_SetForNonlinearLensing(P%Transfer)
    end if

    call Transfer_SortAndIndexRedshifts(P%Transfer)
    !JD 08/13 end changes

    P%transfer%kmax=P%transfer%kmax*(P%h0/100._dl)

    Ini_fail_on_not_found = .false.

    DebugParam = Ini_Read_Double('DebugParam',DebugParam)
    ALens = Ini_Read_Double('Alens',Alens)

    call Reionization_ReadParams(P%Reion, DefIni)
    call InitialPower_ReadParams(P%InitPower, DefIni, P%WantTensors)
    call Recombination_ReadParams(P%Recomb, DefIni)
    if (Ini_HasKey('recombination')) then
        i = Ini_Read_Int('recombination',1)
        if (i/=1) stop 'recombination option deprecated'
    end if

    call Bispectrum_ReadParams(BispectrumParams, DefIni, outroot)

    if (P%WantScalars .or. P%WantTransfer) then
        P%Scalar_initial_condition = Ini_Read_Int('initial_condition',initial_adiabatic)
        if (P%Scalar_initial_condition == initial_vector) then
            P%InitialConditionVector=0
            numstr = Ini_Read_String('initial_vector',.true.)
            read (numstr,*) P%InitialConditionVector(1:initial_iso_neutrino_vel)
        end if
        if (P%Scalar_initial_condition/= initial_adiabatic) use_spline_template = .false.
    end if

    if (P%WantScalars) then
        ScalarFileName = trim(outroot)//Ini_Read_String('scalar_output_file')
        LensedFileName =  trim(outroot) //Ini_Read_String('lensed_output_file')
        LensPotentialFileName =  Ini_Read_String('lens_potential_output_file')
        if (LensPotentialFileName/='') LensPotentialFileName = concat(outroot,LensPotentialFileName)
        ScalarCovFileName =  Ini_Read_String_Default('scalar_covariance_output_file','scalCovCls.dat',.false.)
        if (ScalarCovFileName/='') then
            has_cl_2D_array = .true.
            ScalarCovFileName = concat(outroot,ScalarCovFileName)
        end if
    end if
    if (P%WantTensors) then
        TensorFileName =  trim(outroot) //Ini_Read_String('tensor_output_file')
        if (P%WantScalars)  then
            TotalFileName =  trim(outroot) //Ini_Read_String('total_output_file')
            LensedTotFileName = Ini_Read_String('lensed_total_output_file')
            if (LensedTotFileName/='') LensedTotFileName= trim(outroot) //trim(LensedTotFileName)
        end if
    end if
    if (P%WantVectors) then
        VectorFileName =  trim(outroot) //Ini_Read_String('vector_output_file')
    end if

#ifdef WRITE_FITS
    if (P%WantCls) then
        FITSfilename =  trim(outroot) //Ini_Read_String('FITS_filename',.true.)
        if (FITSfilename /='') then
            inquire(file=FITSfilename, exist=bad)
            if (bad) then
                open(unit=18,file=FITSfilename,status='old')
                close(18,status='delete')
            end if
        end if
    end if
#endif


    Ini_fail_on_not_found = .false.

    !optional parameters controlling the computation

    P%AccuratePolarization = Ini_Read_Logical('accurate_polarization',.true.)
    P%AccurateReionization = Ini_Read_Logical('accurate_reionization',.false.)
    P%AccurateBB = Ini_Read_Logical('accurate_BB',.false.)
    P%DerivedParameters = Ini_Read_Logical('derived_parameters',.true.)

    version_check = Ini_Read_String('version_check')
    if (version_check == '') then
        !tag the output used parameters .ini file with the version of CAMB being used now
        call TNameValueList_Add(DefIni%ReadValues, 'version_check', version)
    else if (version_check /= version) then
        write(*,*) 'WARNING: version_check does not match this CAMB version'
    end if
    !Mess here to fix typo with backwards compatibility
    if (Ini_HasKey('do_late_rad_trunction')) then
        DoLateRadTruncation = Ini_Read_Logical('do_late_rad_trunction',.true.)
        if (Ini_HasKey('do_late_rad_truncation')) stop 'check do_late_rad_xxxx'
    else
        DoLateRadTruncation = Ini_Read_Logical('do_late_rad_truncation',.true.)
    end if

    if (HighAccuracyDefault) then
        DoTensorNeutrinos = .true.
    else
        DoTensorNeutrinos = Ini_Read_Logical('do_tensor_neutrinos',DoTensorNeutrinos )
    end if
    FeedbackLevel = Ini_Read_Int('feedback_level',FeedbackLevel)

    P%MassiveNuMethod  = Ini_Read_Int('massive_nu_approx',Nu_best)

    ThreadNum      = Ini_Read_Int('number_of_threads',ThreadNum)
    use_spline_template = Ini_Read_Logical('use_spline_template',use_spline_template)

    if (do_bispectrum) then
        lSampleBoost   = 50
    else
        lSampleBoost   = Ini_Read_Double('l_sample_boost',lSampleBoost)
    end if

    ! get the number of parameters:
    param_number = P%EFTCAMB%model%parameter_number

    ! decide the sampling range:
    ! if the maximum and minimum of a parameter are specified by the user
    ! then use those. If they are not decide the range based on the
    ! value of the parameter entered.
    if ( param_number == 0 ) then
        ! if there is no parameter to sample exit
        stop 0
    else if ( param_number > 0 ) then

        ! get the maximum of the first parameter:
        if ( Ini_HasKey('param_1_max') ) then
            param_1_max = Ini_Read_Double( 'param_1_max' )
        else
            call P%EFTCAMB%model%parameter_values( 1, value = param_1_max )
        end if

        ! get the minimum of the first parameter:
        if ( Ini_HasKey('param_1_min') ) then
            param_1_min = Ini_Read_Double( 'param_1_min' )
        else
            if ( param_1_max < log_sampling_value ) then
                param_1_min = log_sampling_min
            else
                param_1_min = -param_1_max
            end if
        end if

        ! get log sampling if wanted:
        do_log_sampling_param_1 = Ini_Read_Logical( 'do_log_sampling_param_1', .False. )

        if ( param_number > 1 ) then

            ! get the maximum of the second parameter:
            if ( Ini_HasKey('param_2_max') ) then
                param_2_max = Ini_Read_Double( 'param_2_max' )
            else
                call P%EFTCAMB%model%parameter_values( 2, value = param_2_max )
            end if

            ! get the minimum of the second parameter:
            if ( Ini_HasKey('param_2_min') ) then
                param_2_min = Ini_Read_Double( 'param_2_min' )
            else
                if ( param_2_max < log_sampling_value ) then
                    param_2_min = log_sampling_min
                else
                    param_2_min = -param_2_max
                end if
            end if

            ! get log sampling if wanted:
            do_log_sampling_param_2 = Ini_Read_Logical( 'do_log_sampling_param_2', .False. )

        else if ( param_number > 2 ) then

            print*, 'EFTCAMB stability sampler error:'
            print*, ' The model has more than two parameters.'
            print*, ' Simple sampling algorithms cannot handle that.'
            stop 1

        end if

    end if

    call Ini_Close

    if (.not. CAMB_ValidateParams(P)) stop 'Stopped due to parameter error'

    FeedbackLevel = 0

    ! do the sampling and save to file:


    call CAMB_cleanup
    stop

100 stop 'Must give num_massive number of integer physical neutrinos for each eigenstate'

end program stability_sampler
