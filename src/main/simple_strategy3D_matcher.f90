! projection-matching based on Hadamard products, high-level search routines for REFINE3D
module simple_strategy3D_matcher
!$ use omp_lib
!$ use omp_lib_kinds
include 'simple_lib.f08'
use simple_strategy3D_alloc ! singleton s3D
use simple_timer
use simple_o_peaks_io
use simple_oris,                     only: oris
use simple_qsys_funs,                only: qsys_job_finished
use simple_binoris_io,               only: binwrite_oritab
use simple_kbinterpol,               only: kbinterpol
use simple_ori,                      only: ori
use simple_sym,                      only: sym
use simple_image,                    only: image
use simple_cmdline,                  only: cmdline
use simple_parameters,               only: params_glob
use simple_builder,                  only: build_glob
use simple_polarizer,                only: polarizer
use simple_polarft_corrcalc,         only: polarft_corrcalc
use simple_strategy2D3D_common,      only: killrecvols, set_bp_range, preprecvols,&
    prepimgbatch, grid_ptcl, read_imgbatch, norm_struct_facts
use simple_strategy3D_cluster,       only: strategy3D_cluster
use simple_strategy3D_clustersoft,   only: strategy3D_clustersoft
use simple_strategy3D_single,        only: strategy3D_single
use simple_strategy3D_multi,         only: strategy3D_multi
use simple_strategy3D_snhc_single,   only: strategy3D_snhc_single
use simple_strategy3D_greedy_single, only: strategy3D_greedy_single
use simple_strategy3D_greedy_multi,  only: strategy3D_greedy_multi
use simple_strategy3D_neigh_single,  only: strategy3D_neigh_single
use simple_strategy3D_neigh_multi,   only: strategy3D_neigh_multi
use simple_strategy3D_cont_single,   only: strategy3D_cont_single
use simple_strategy3D,               only: strategy3D
use simple_strategy3D_srch,          only: strategy3D_spec, set_ptcl_stats, eval_ptcl
use simple_convergence,              only: convergence
use simple_euclid_sigma2,            only: euclid_sigma2
implicit none

public :: refine3D_exec, preppftcc4align, pftcc, setup_weights_read_o_peaks
public :: calc_3Drec, calc_proj_weights
private
#include "simple_local_flags.inc"

logical, parameter             :: L_BENCH = .false., DEBUG_HERE = .false.
logical                        :: has_been_searched
type(polarft_corrcalc), target :: pftcc
type(polarizer),   allocatable :: match_imgs(:)
integer,           allocatable :: prev_states(:), pinds(:)
logical,           allocatable :: ptcl_mask(:)
type(sym)                      :: c1_symop
integer                        :: nptcls2update
integer                        :: npeaks
integer(timer_int_kind)        :: t_init, t_prep_pftcc, t_align, t_rec, t_tot, t_prep_primesrch3D
real(timer_int_kind)           :: rt_init, rt_prep_pftcc, rt_align, rt_rec, rt_prep_primesrch3D
real(timer_int_kind)           :: rt_tot
character(len=STDLEN)          :: benchfname
type(euclid_sigma2)            :: eucl_sigma

contains

    subroutine refine3D_exec( cline, which_iter, converged )
        class(cmdline),        intent(inout) :: cline
        integer,               intent(in)    :: which_iter
        logical,               intent(inout) :: converged
        integer, target, allocatable :: symmat(:,:)
        logical,         allocatable :: het_mask(:)
        !---> The below is to allow particle-dependent decision about which 3D strategy to use
        type :: strategy3D_per_ptcl
            class(strategy3D), pointer :: ptr  => null()
        end type strategy3D_per_ptcl
        type(strategy3D_per_ptcl), allocatable :: strategy3Dsrch(:)
        !<---- hybrid or combined search strategies can then be implemented as extensions of the
        !      relevant strategy3D base class
        type(strategy3D_spec),     allocatable :: strategy3Dspecs(:)
        type(convergence)     :: conv
        type(oris)            :: o_peak_prev
        real,    allocatable  :: resarr(:)
        integer, allocatable  :: batches(:,:)
        real    :: frac_srch_space, extr_thresh, extr_score_thresh, mi_proj, anneal_ratio
        integer :: nbatches, batchsz_max, batch_start, batch_end, batchsz, imatch
        integer :: iptcl, fnr, ithr, updatecnt, state, n_nozero, iptcl_batch, iptcl_map
        integer :: ibatch, iextr_lim, lpind_anneal, lpind_start
        logical :: doprint, do_extr, l_ctf

        if( L_BENCH )then
            t_init = tic()
            t_tot  = t_init
        endif

        ! CHECK THAT WE HAVE AN EVEN/ODD PARTITIONING
        if( build_glob%spproj_field%get_nevenodd() == 0 ) THROW_HARD('no eo partitioning available; refine3D_exec')

        ! CHECK WHETHER WE HAVE PREVIOUS 3D ORIENTATIONS
        has_been_searched = .not.build_glob%spproj%is_virgin_field(params_glob%oritype)

        ! SET FOURIER INDEX RANGE
        call set_bp_range(cline)

        ! DETERMINE THE NUMBER OF PEAKS
        select case(params_glob%refine)
            case('cluster', 'snhc', 'clustersym', 'cont_single', 'eval')
                npeaks = 1
            case DEFAULT
                npeaks = NPEAKS2REFINE
                ! command line overrides
                if( cline%defined('npeaks') ) npeaks = params_glob%npeaks
        end select
        if( DEBUG_HERE ) write(logfhandle,*) '*** strategy3D_matcher ***: determined the number of peaks'

        ! SET FRACTION OF SEARCH SPACE
        frac_srch_space = build_glob%spproj_field%get_avg('frac')

        ! READ FOURIER RING CORRELATIONS
        if( params_glob%nstates.eq.1 )then
            if( file_exists(params_glob%frcs) ) call build_glob%projfrcs%read(params_glob%frcs)
        else
            if( file_exists(CLUSTER3D_FRCS) )then
                call build_glob%projfrcs%read(CLUSTER3D_FRCS)
            else
                if( file_exists(params_glob%frcs) )then
                    call build_glob%projfrcs%read(params_glob%frcs)
                endif
            endif
        endif

        ! PARTICLE INDEX SAMPLING FOR FRACTIONAL UPDATE (OR NOT)
        if( allocated(pinds) )     deallocate(pinds)
        if( allocated(ptcl_mask) ) deallocate(ptcl_mask)
        if( params_glob%l_frac_update )then
            allocate(ptcl_mask(params_glob%fromp:params_glob%top))
            call build_glob%spproj_field%sample4update_and_incrcnt([params_glob%fromp,params_glob%top],&
            &params_glob%update_frac, nptcls2update, pinds, ptcl_mask)
        else
            allocate(ptcl_mask(params_glob%fromp:params_glob%top))
            call build_glob%spproj_field%sample4update_and_incrcnt_nofrac([params_glob%fromp,params_glob%top],&
            nptcls2update, pinds, ptcl_mask)
        endif

        ! EXTREMAL LOGICS
        do_extr           = .false.
        extr_score_thresh = -huge(extr_score_thresh)
        select case(trim(params_glob%refine))
            case('cluster','clustersym','clustersoft')
                ! general logics
                if(allocated(het_mask))deallocate(het_mask)
                allocate(het_mask(params_glob%fromp:params_glob%top), source=ptcl_mask)
                call build_glob%spproj_field%set_extremal_vars(params_glob%extr_init, params_glob%extr_iter,&
                    &which_iter, frac_srch_space, do_extr, iextr_lim, update_frac=params_glob%update_frac)
                if( do_extr )then
                    anneal_ratio      = max(0., cos(PI/2.*real(params_glob%extr_iter-1)/real(iextr_lim)))
                    extr_thresh       = params_glob%extr_init * anneal_ratio
                    extr_score_thresh = build_glob%spproj_field%extremal_bound(extr_thresh, 'corr')
                    if( cline%defined('lpstart') )then
                        ! resolution limit update
                        lpind_start       = calc_fourier_index(params_glob%lpstart,params_glob%boxmatch,params_glob%smpd)
                        lpind_anneal      = nint(real(lpind_start) + (1.-anneal_ratio)*real(params_glob%kstop-lpind_start))
                        params_glob%kstop = min(lpind_anneal, params_glob%kstop)
                        resarr            = build_glob%img%get_res()
                        params_glob%lp    = resarr(params_glob%kstop)
                        if( params_glob%cc_objfun .ne. OBJFUN_EUCLID ) params_glob%kfromto(2) = params_glob%kstop
                        call build_glob%spproj_field%set_all2single('lp',params_glob%lp)
                        deallocate(resarr)
                    endif
                else
                    het_mask = .false.
                endif
                ! refinement mode specifics
                select case(trim(params_glob%refine))
                    case('clustersym')
                       ! symmetry pairing matrix
                        c1_symop = sym('c1')
                        params_glob%nspace = min(params_glob%nspace*build_glob%pgrpsyms%get_nsym(), 2500)
                        call build_glob%eulspace%new( params_glob%nspace )
                        call build_glob%eulspace%spiral
                        call build_glob%pgrpsyms%nearest_sym_neighbors(build_glob%eulspace, symmat)
                    case('clustersoft')
                        prev_states = nint(build_glob%spproj_field%get_all('state',[params_glob%fromp,params_glob%top]))
                end select
            case('clsneigh_multi','clsneigh_single')
                call build_glob%spproj_field%set_extremal_vars(params_glob%extr_init, params_glob%extr_iter,&
                    &which_iter, frac_srch_space, do_extr, iextr_lim, update_frac=params_glob%update_frac)
                anneal_ratio = max(0., cos(PI/2.*real(params_glob%extr_iter-1)/real(iextr_lim)))
                extr_thresh  = params_glob%extr_init * anneal_ratio
        end select
        if( L_BENCH ) rt_init = toc(t_init)

        ! PREP BATCH ALIGNEMENT
        batchsz_max = min(nptcls2update,params_glob%nthr*BATCHTHRSZ)
        nbatches    = ceiling(real(nptcls2update)/real(batchsz_max))
        batches     = split_nobjs_even(nptcls2update, nbatches)
        batchsz_max = maxval(batches(:,2)-batches(:,1)+1)

        ! PREPARE THE POLARFT_CORRCALC DATA STRUCTURE
        if( L_BENCH ) t_prep_pftcc = tic()
        call preppftcc4align(cline, batchsz_max)
        if( L_BENCH ) rt_prep_pftcc = toc(t_prep_pftcc)

        ! STOCHASTIC IMAGE ALIGNMENT
        if( L_BENCH ) t_prep_primesrch3D = tic()
        write(logfhandle,'(A,1X,I3)') '>>> REFINE3D SEARCH, ITERATION:', which_iter
        ! clean big objects before starting to allocate new big memory chunks
        ! cannot kill build_glob%vol since used in continuous search
        call build_glob%vol2%kill
        ! array allocation for strategy3D
        if( DEBUG_HERE ) write(logfhandle,*) '*** strategy3D_matcher ***: array allocation for strategy3D'
        call prep_strategy3D( ptcl_mask, npeaks ) ! allocate s3D singleton
        if( DEBUG_HERE ) write(logfhandle,*) '*** strategy3D_matcher ***: array allocation for strategy3D, DONE'
        if( L_BENCH ) rt_prep_primesrch3D = toc(t_prep_primesrch3D)

        ! read o_peaks for neigh refinement modes
        if( str_has_substr(params_glob%refine, 'clsneigh') )then
            ! nothing to do
        else if( str_has_substr(params_glob%refine, 'neigh') )then
            call read_o_peaks
        endif

        ! GENERATE PARTICLES IMAGE OBJECTS
        call build_glob%img_match%init_polarizer(pftcc, params_glob%alpha)
        allocate(match_imgs(batchsz_max),strategy3Dspecs(batchsz_max),strategy3Dsrch(batchsz_max),stat=alloc_stat)
        if(alloc_stat.ne.0) call allocchk("In simple_strategy3D_matcher::refine3D_exec strategy3Dsrch",alloc_stat)
        call prepimgbatch(batchsz_max)
        !$omp parallel do default(shared) private(imatch) schedule(static) proc_bind(close)
        do imatch=1,batchsz_max
            call match_imgs(imatch)%new([params_glob%boxmatch, params_glob%boxmatch, 1], params_glob%smpd)
            call match_imgs(imatch)%copy_polarizer(build_glob%img_match)
        end do
        !$omp end parallel do

        ! SEARCH
        rt_align = 0.
        if( trim(params_glob%oritype) .eq. 'ptcl3D' )then
            l_ctf = build_glob%spproj%get_ctfflag('ptcl3D').ne.'no'
        else
            ! class averages have no CTF
            l_ctf = .false.
        endif
        write(logfhandle,'(A,1X,I3)') '>>> REFINE3D SEARCH, ITERATION:', which_iter
        ! Batch loop
        do ibatch=1,nbatches
            batch_start = batches(ibatch,1)
            batch_end   = batches(ibatch,2)
            batchsz     = batch_end - batch_start + 1
            ! Prep particles in pftcc
            if( L_BENCH ) t_prep_pftcc = tic()
            call build_pftcc_batch_particles(batchsz, pinds(batch_start:batch_end))
            if( l_ctf ) call pftcc%create_polar_absctfmats(build_glob%spproj, 'ptcl3D')
            if( L_BENCH ) rt_prep_pftcc = rt_prep_pftcc + toc(t_prep_pftcc)
            if( trim(params_glob%refine).eq.'clustersoft' )then
                call open_o_peaks_io(trim(params_glob%o_peaks_file))
                do iptcl_batch = 1,batchsz
                    iptcl_map  = batch_start + iptcl_batch - 1
                    iptcl      = pinds(iptcl_map)
                    call read_o_peak(s3D%o_peaks(iptcl), [params_glob%fromp,params_glob%top], iptcl, n_nozero)
                enddo
                call close_o_peaks_io
            endif
            ! Particles loop
            if( L_BENCH ) t_align = tic()
            !$omp parallel do default(shared) private(iptcl,iptcl_batch,iptcl_map,ithr,updatecnt)&
            !$omp schedule(static) proc_bind(close)
            do iptcl_batch = 1,batchsz                     ! particle batch index
                iptcl_map  = batch_start + iptcl_batch - 1 ! masked global index (cumulative)
                iptcl      = pinds(iptcl_map)              ! global index
                ithr       = omp_get_thread_num() + 1
                ! switch for per-particle polymorphic strategy3D construction
                select case(trim(params_glob%refine))
                    case('snhc')
                        allocate(strategy3D_snhc_single       :: strategy3Dsrch(iptcl_batch)%ptr)
                    case('single')
                        if( .not.build_glob%spproj_field%has_been_searched(iptcl) .or. ran3() < GREEDY_FREQ )then
                            allocate(strategy3D_greedy_single :: strategy3Dsrch(iptcl_batch)%ptr)
                        else
                            allocate(strategy3D_single        :: strategy3Dsrch(iptcl_batch)%ptr)
                        endif
                    case('greedy_single')
                        allocate(strategy3D_greedy_single     :: strategy3Dsrch(iptcl_batch)%ptr)
                    case('cont_single')
                        allocate(strategy3D_cont_single       :: strategy3Dsrch(iptcl_batch)%ptr)
                    case('multi')
                        updatecnt = nint(build_glob%spproj_field%get(iptcl,'updatecnt'))
                        if( .not.build_glob%spproj_field%has_been_searched(iptcl) .or. updatecnt == 1 )then
                            allocate(strategy3D_greedy_multi  :: strategy3Dsrch(iptcl_batch)%ptr)
                        else
                            allocate(strategy3D_multi         :: strategy3Dsrch(iptcl_batch)%ptr)
                        endif
                    case('greedy_multi')
                        allocate(strategy3D_greedy_multi      :: strategy3Dsrch(iptcl_batch)%ptr)
                    case('cluster','clustersym')
                        allocate(strategy3D_cluster           :: strategy3Dsrch(iptcl_batch)%ptr)
                    case('clustersoft')
                        allocate(strategy3D_clustersoft       :: strategy3Dsrch(iptcl_batch)%ptr)
                    case('neigh_single')
                        allocate(strategy3D_neigh_single      :: strategy3Dsrch(iptcl_batch)%ptr)
                    case('clsneigh_single')
                        if( trim(params_glob%anneal).eq.'no' )then
                            allocate(strategy3D_neigh_single  :: strategy3Dsrch(iptcl_batch)%ptr)
                        else
                            if( ran3() <= extr_thresh )then
                                allocate(strategy3D_neigh_single  :: strategy3Dsrch(iptcl_batch)%ptr)
                            else
                                if( .not.build_glob%spproj_field%has_been_searched(iptcl) .or. ran3() < GREEDY_FREQ )then
                                    allocate(strategy3D_greedy_single :: strategy3Dsrch(iptcl_batch)%ptr)
                                else
                                    allocate(strategy3D_single    :: strategy3Dsrch(iptcl_batch)%ptr)
                                endif
                            endif
                        endif
                    case('neigh_multi')
                        allocate(strategy3D_neigh_multi       :: strategy3Dsrch(iptcl_batch)%ptr)
                    case('clsneigh_multi')
                        if( ran3() <= extr_thresh )then
                            allocate(strategy3D_neigh_multi   :: strategy3Dsrch(iptcl_batch)%ptr)
                        else
                            updatecnt = nint(build_glob%spproj_field%get(iptcl,'updatecnt'))
                            if( .not.build_glob%spproj_field%has_been_searched(iptcl) .or. updatecnt == 1 )then
                                allocate(strategy3D_greedy_multi :: strategy3Dsrch(iptcl_batch)%ptr)
                            else
                                allocate(strategy3D_multi     :: strategy3Dsrch(iptcl_batch)%ptr)
                            endif
                        endif
                    case('eval')
                        call eval_ptcl(pftcc, iptcl)
                        cycle !!
                    case DEFAULT
                        THROW_HARD('refinement mode: '//trim(params_glob%refine)//' unsupported')
                end select
                ! ACTUAL SEARCH
                strategy3Dspecs(iptcl_batch)%iptcl =  iptcl
                strategy3Dspecs(iptcl_batch)%szsn  =  params_glob%szsn
                strategy3Dspecs(iptcl_batch)%extr_score_thresh = extr_score_thresh
                if( allocated(het_mask) ) strategy3Dspecs(iptcl_batch)%do_extr =  het_mask(iptcl)
                if( allocated(symmat)   ) strategy3Dspecs(iptcl_batch)%symmat  => symmat
                ! search object
                call strategy3Dsrch(iptcl_batch)%ptr%new(strategy3Dspecs(iptcl_batch), npeaks)
                ! search
                call strategy3Dsrch(iptcl_batch)%ptr%srch(ithr)
                ! cleanup
                call strategy3Dsrch(iptcl_batch)%ptr%kill
                ! calculate sigma2 for ML-based refinement
                if ( params_glob%l_needs_sigma ) then
                    if( params_glob%which_iter > 1 )then
                        call eucl_sigma%calc_sigma2(build_glob%spproj_field, iptcl, s3D%o_peaks(iptcl))
                    endif
                end if
            enddo ! Particles loop
            !$omp end parallel do
            if( L_BENCH ) rt_align = rt_align + toc(t_align)
        enddo
        ! cleanup
        do iptcl_batch = 1,batchsz_max
            nullify(strategy3Dsrch(iptcl_batch)%ptr)
        end do
        deallocate(strategy3Dsrch,strategy3Dspecs,batches)

        ! WRITE SIGMAS FOR ML-BASED REFINEMENT
        if ( params_glob%l_needs_sigma ) then
            call eucl_sigma%write_sigma2
            ! call eucl_sigma%write_model(build_glob%spproj_field, [params_glob%fromp,params_glob%top],&
            !     &s3D%o_peaks, build_glob%eulspace, which_iter)
        end if

        ! UPDATE PARTICLE STATS
        call calc_ptcl_stats( batchsz_max, l_ctf )

        ! O_PEAKS I/O & CONVERGENCE STATS
        ! here we read all peaks to allow deriving statistics based on the complete set
        ! this is needed for deriving projection direction weights
        select case(trim(params_glob%refine))
            case('eval','cluster','clustersym')
                ! nothing to do
            case DEFAULT
                if( .not. file_exists(trim(params_glob%o_peaks_file)) )then
                    ! write an empty one to be filled in
                    call write_empty_o_peaks_file(params_glob%o_peaks_file, [params_glob%fromp,params_glob%top])
                endif
                call open_o_peaks_io(trim(params_glob%o_peaks_file))
                do iptcl=params_glob%fromp,params_glob%top
                    if( ptcl_mask(iptcl) )then
                        state = build_glob%spproj_field%get_state(iptcl)
                        call read_o_peak(o_peak_prev, [params_glob%fromp,params_glob%top], iptcl, n_nozero)
                        if( n_nozero == 0 )then
                            ! there's nothing to compare, set overlap to zero
                            call build_glob%spproj_field%set(iptcl, 'mi_proj', 0.)
                        else
                            mi_proj = s3D%o_peaks(iptcl)%overlap(o_peak_prev, 'proj', state)
                            call build_glob%spproj_field%set(iptcl, 'mi_proj', mi_proj)
                        endif
                        ! replace the peak on disc
                        call write_o_peak(s3D%o_peaks(iptcl), [params_glob%fromp,params_glob%top], iptcl)
                    else
                        call read_o_peak(s3D%o_peaks(iptcl), [params_glob%fromp,params_glob%top], iptcl, n_nozero)
                    endif
                end do
                call close_o_peaks_io
        end select
        call o_peak_prev%kill

        ! CALCULATE PROJECTION DIRECTION WEIGHTS
        ! call calc_proj_weights !!!!!!!!!! turned off 4 now, needs integration and testing

        ! CALCULATE PARTICLE WEIGHTS
        select case(trim(params_glob%ptclw))
            case('yes')
                call build_glob%spproj_field%calc_soft_weights(params_glob%frac)
            case DEFAULT
                call build_glob%spproj_field%calc_hard_weights(params_glob%frac)
        end select

        ! CLEAN
        call clean_strategy3D ! deallocate s3D singleton
        call pftcc%kill
        call build_glob%vol%kill
        call build_glob%vol_odd%kill
        do ibatch=1,batchsz_max
            call match_imgs(ibatch)%kill_polarizer
            call match_imgs(ibatch)%kill
        end do
        deallocate(match_imgs)
        if( L_BENCH ) rt_align = toc(t_align)
        if( allocated(symmat)   ) deallocate(symmat)
        if( allocated(het_mask) ) deallocate(het_mask)

        ! OUTPUT ORIENTATIONS
        select case(trim(params_glob%oritype))
            case('ptcl3D')
                call binwrite_oritab(params_glob%outfile, build_glob%spproj, &
                    &build_glob%spproj_field, [params_glob%fromp,params_glob%top], isegment=PTCL3D_SEG)
            case('cls3D')
                call binwrite_oritab(params_glob%outfile, build_glob%spproj, &
                    &build_glob%spproj_field, [params_glob%fromp,params_glob%top], isegment=CLS3D_SEG)
            case DEFAULT
                THROW_HARD('unsupported oritype: '//trim(params_glob%oritype)//'; refine3D_exec')
        end select
        params_glob%oritab = params_glob%outfile

        ! VOLUMETRIC 3D RECONSTRUCTION
        call calc_3Drec( cline, which_iter )
        call eucl_sigma%kill

        ! REPORT CONVERGENCE
        call qsys_job_finished(  'simple_strategy3D_matcher :: refine3D_exec')
        if( .not. params_glob%l_distr_exec ) converged = conv%check_conv3D(cline, params_glob%msk)
        if( L_BENCH )then
            rt_tot  = toc(t_tot)
            doprint = .true.
            if( params_glob%part /= 1 ) doprint = .false.
            if( doprint )then
                benchfname = 'HADAMARD3D_BENCH_ITER'//int2str_pad(which_iter,3)//'.txt'
                call fopen(fnr, FILE=trim(benchfname), STATUS='REPLACE', action='WRITE')
                write(fnr,'(a)') '*** TIMINGS (s) ***'
                write(fnr,'(a,1x,f9.2)') 'initialisation          : ', rt_init
                write(fnr,'(a,1x,f9.2)') 'pftcc preparation       : ', rt_prep_pftcc
                write(fnr,'(a,1x,f9.2)') 'primesrch3D preparation : ', rt_prep_primesrch3D
                write(fnr,'(a,1x,f9.2)') 'stochastic alignment    : ', rt_align
                write(fnr,'(a,1x,f9.2)') 'reconstruction          : ', rt_rec
                write(fnr,'(a,1x,f9.2)') 'total time              : ', rt_tot
                write(fnr,'(a)') ''
                write(fnr,'(a)') '*** RELATIVE TIMINGS (%) ***'
                write(fnr,'(a,1x,f9.2)') 'initialisation          : ', (rt_init/rt_tot)             * 100.
                write(fnr,'(a,1x,f9.2)') 'pftcc preparation       : ', (rt_prep_pftcc/rt_tot)       * 100.
                write(fnr,'(a,1x,f9.2)') 'primesrch3D preparation : ', (rt_prep_primesrch3D/rt_tot) * 100.
                write(fnr,'(a,1x,f9.2)') 'stochastic alignment    : ', (rt_align/rt_tot)            * 100.
                write(fnr,'(a,1x,f9.2)') 'reconstruction          : ', (rt_rec/rt_tot)              * 100.
                write(fnr,'(a,1x,f9.2)') '% accounted for         : ',&
                    &((rt_init+rt_prep_pftcc+rt_prep_primesrch3D+rt_align+rt_rec)/rt_tot) * 100.
                call fclose(fnr)
            endif
        endif
    end subroutine refine3D_exec

    !> Prepare alignment search using polar projection Fourier cross correlation
    subroutine preppftcc4align( cline, batchsz_max )
        use simple_cmdline,             only: cmdline
        use simple_strategy2D3D_common, only: calcrefvolshift_and_mapshifts2ptcls, preprefvol
        class(cmdline), intent(inout) :: cline !< command line
        integer,        intent(in)    :: batchsz_max
        type(ori) :: o_tmp
        real      :: xyz(3)
        integer   :: cnt, s, ind, iref, nrefs
        logical   :: do_center
        character(len=:), allocatable :: fname
        nrefs = params_glob%nspace * params_glob%nstates
        ! must be done here since params_glob%kfromto is dynamically set
        call pftcc%new(nrefs, [1,batchsz_max])
        if ( params_glob%l_needs_sigma ) then
            fname = SIGMA2_FBODY//int2str_pad(params_glob%part,params_glob%numlen)//'.dat'
            call eucl_sigma%new(fname)
            call eucl_sigma%read_part(  build_glob%spproj_field, ptcl_mask)
            call eucl_sigma%read_groups(build_glob%spproj_field, ptcl_mask)
        end if
        ! PREPARATION OF REFERENCES IN PFTCC
        ! read reference volumes and create polar projections
        cnt = 0
        do s=1,params_glob%nstates
            if( str_has_substr(params_glob%refine,'greedy') )then
                if( .not.file_exists(params_glob%vols(s)) )then
                    cnt = cnt + params_glob%nspace
                    call progress(cnt, nrefs)
                    cycle
                endif
            else
                if( has_been_searched )then
                    if( build_glob%spproj_field%get_pop(s, 'state') == 0 )then
                        ! empty state
                        cnt = cnt + params_glob%nspace
                        call progress(cnt, nrefs)
                        cycle
                    endif
                endif
            endif
            call calcrefvolshift_and_mapshifts2ptcls( cline, s, params_glob%vols(s), do_center, xyz)
            if( params_glob%l_lpset )then
                ! low-pass set or multiple states
                call preprefvol(pftcc, cline, s, params_glob%vols(s), do_center, xyz, .true.)
                !$omp parallel do default(shared) private(iref, o_tmp) schedule(static) proc_bind(close)
                do iref=1,params_glob%nspace
                    call build_glob%eulspace%get_ori(iref, o_tmp)
                    call build_glob%vol%fproject_polar((s - 1) * params_glob%nspace + iref, &
                        &o_tmp, pftcc, iseven=.true., mask=build_glob%l_resmsk)
                    call o_tmp%kill
                end do
                !$omp end parallel do
            else
                if( params_glob%nstates.eq.1 )then
                    ! PREPARE ODD REFERENCES
                    call preprefvol(pftcc, cline, s, params_glob%vols_odd(s), do_center, xyz, .false.)
                    !$omp parallel do default(shared) private(iref, o_tmp) schedule(static) proc_bind(close)
                    do iref=1,params_glob%nspace
                        call build_glob%eulspace%get_ori(iref, o_tmp)
                        call build_glob%vol%fproject_polar((s - 1) * params_glob%nspace + iref, &
                            &o_tmp, pftcc, iseven=.false., mask=build_glob%l_resmsk)
                        call o_tmp%kill
                    end do
                    !$omp end parallel do
                    ! copy odd volume
                    build_glob%vol_odd = build_glob%vol
                    ! expand for fast interpolation
                    call build_glob%vol_odd%expand_cmat(params_glob%alpha,norm4proj=.true.)
                    ! PREPARE EVEN REFERENCES
                    call preprefvol(pftcc,  cline, s, params_glob%vols_even(s), do_center, xyz, .true.)
                    !$omp parallel do default(shared) private(iref, o_tmp) schedule(static) proc_bind(close)
                    do iref=1,params_glob%nspace
                        call build_glob%eulspace%get_ori(iref, o_tmp)
                        call build_glob%vol%fproject_polar((s - 1) * params_glob%nspace + iref, &
                            &o_tmp, pftcc, iseven=.true., mask=build_glob%l_resmsk)
                        call o_tmp%kill
                    end do
                    !$omp end parallel do
                else
                    call preprefvol(pftcc, cline, s, params_glob%vols(s), do_center, xyz, .true.)
                    !$omp parallel do default(shared) private(iref, ind, o_tmp) schedule(static) proc_bind(close)
                    do iref=1,params_glob%nspace
                        ind = (s - 1) * params_glob%nspace + iref
                        call build_glob%eulspace%get_ori(iref, o_tmp)
                        call build_glob%vol%fproject_polar(ind, o_tmp, pftcc, iseven=.true., mask=build_glob%l_resmsk)
                        call pftcc%cp_even2odd_ref(ind)
                        call o_tmp%kill
                    end do
                    !$omp end parallel do
                endif
            endif
        end do
        if( params_glob%l_needs_sigma .and. params_glob%cc_objfun /= OBJFUN_EUCLID ) then
            ! When calculating sigma2 prior to OBJFUN_EUCLID the references are zeroed out
            !  beyond the resolution limit such that sigma2 is the weighted sum of particle power spectrum
            call pftcc%zero_refs_beyond_kstop
        endif
        if( DEBUG_HERE ) write(logfhandle,*) '*** strategy3D_matcher ***: finished preppftcc4align'
    end subroutine preppftcc4align

    !>  \brief  prepares batch particle images for alignment
    subroutine build_pftcc_batch_particles( nptcls_here, pinds_here )
        use simple_strategy2D3D_common, only: read_imgbatch, prepimg4align
        integer, intent(in) :: nptcls_here
        integer, intent(in) :: pinds_here(nptcls_here)
        integer :: iptcl_batch, iptcl
        call read_imgbatch( nptcls_here, pinds_here, [1,nptcls_here] )
        ! reassign particles indices & associated variables
        call pftcc%reallocate_ptcls(nptcls_here, pinds_here)
        !$omp parallel do default(shared) private(iptcl,iptcl_batch) schedule(static) proc_bind(close)
        do iptcl_batch = 1,nptcls_here
            iptcl = pinds_here(iptcl_batch)
            ! prep
            call match_imgs(iptcl_batch)%zero_and_unflag_ft
            call prepimg4align(iptcl, build_glob%imgbatch(iptcl_batch), match_imgs(iptcl_batch))
            ! transfer to polar coordinates
            call match_imgs(iptcl_batch)%polarize(pftcc, iptcl, .true., .true., mask=build_glob%l_resmsk)
            ! e/o flag
            if( params_glob%l_lpset )then
                call pftcc%set_eo(iptcl, .true. )
            else
                call pftcc%set_eo(iptcl, nint(build_glob%spproj_field%get(iptcl,'eo'))<=0 )
            endif
        end do
        !$omp end parallel do
        ! Memoize particles FFT parameters
        call pftcc%memoize_ffts
    end subroutine build_pftcc_batch_particles

    !> Prepare alignment search using polar projection Fourier cross correlation
    subroutine calc_ptcl_stats( batchsz_max, l_ctf )
        use simple_strategy2D3D_common, only: prepimg4align
        integer,   intent(in) :: batchsz_max
        logical,   intent(in) :: l_ctf
        integer, allocatable  :: pinds_here(:), batches(:,:)
        integer :: nptcls, iptcl_batch, iptcl, nbatches, ibatch, batch_start, batch_end, iptcl_map, batchsz
        if( .not.params_glob%l_frac_update ) return
        select case(params_glob%refine)
            case('cluster','clustersym','clustersoft','eval')
                return
            case DEFAULT
                ! all good
        end select
        ! build local particles index map
        nptcls = 0
        do iptcl = params_glob%fromp,params_glob%top
            if( .not.ptcl_mask(iptcl) )then
                if( build_glob%spproj_field%get_state(iptcl) > 0 ) nptcls = nptcls + 1
            endif
        enddo
        if( nptcls == 0 ) return
        allocate(pinds_here(nptcls),source=0)
        nptcls = 0
        do iptcl = params_glob%fromp,params_glob%top
            if( .not.ptcl_mask(iptcl) )then
                if( build_glob%spproj_field%get_state(iptcl) > 0 )then
                    nptcls = nptcls + 1
                    pinds_here(nptcls) = iptcl
                endif
            endif
        enddo
        ! Batch loop
        nbatches = ceiling(real(nptcls)/real(batchsz_max))
        batches  = split_nobjs_even(nptcls, nbatches)
        do ibatch=1,nbatches
            batch_start = batches(ibatch,1)
            batch_end   = batches(ibatch,2)
            batchsz     = batch_end - batch_start + 1
            call build_pftcc_batch_particles(batchsz, pinds_here(batch_start:batch_end))
            if( l_ctf ) call pftcc%create_polar_absctfmats(build_glob%spproj, 'ptcl3D')
            !$omp parallel do default(shared) private(iptcl,iptcl_batch,iptcl_map)&
            !$omp schedule(static) proc_bind(close)
            do iptcl_batch = 1,batchsz                     ! particle batch index
                iptcl_map  = batch_start + iptcl_batch - 1 ! masked global index (cumulative batch index)
                iptcl      = pinds_here(iptcl_map)         ! global index
                call set_ptcl_stats(pftcc, iptcl)
            enddo
            !$omp end parallel do
        enddo
    end subroutine calc_ptcl_stats

    !> volumetric 3d reconstruction
    subroutine calc_3Drec( cline, which_iter )
        use simple_fplane, only: fplane
        class(cmdline), intent(inout) :: cline
        integer,        intent(in)    :: which_iter
        type(fplane),    allocatable  :: fpls(:)
        type(ctfparams), allocatable  :: ctfparms(:)
        type(ori)        :: orientation
        type(kbinterpol) :: kbwin
        real    :: sdev_noise
        integer :: batchlims(2), iptcl, i, i_batch, ibatch
        if( trim(params_glob%dorec) .eq. 'no' ) return
        select case(trim(params_glob%refine))
            case('eval')
                ! no reconstruction
            case DEFAULT
                c1_symop = sym('c1')
                ! make the gridding prepper
                kbwin = build_glob%eorecvols(1)%get_kbwin()
                ! init volumes
                call preprecvols
                ! prep batch imgs
                call prepimgbatch(MAXIMGBATCHSZ)
                ! allocate array
                allocate(fpls(MAXIMGBATCHSZ),ctfparms(MAXIMGBATCHSZ))
                ! prep batch imgs
                call prepimgbatch(MAXIMGBATCHSZ)
                ! gridding batch loop
                do i_batch=1,nptcls2update,MAXIMGBATCHSZ
                    batchlims = [i_batch,min(nptcls2update,i_batch + MAXIMGBATCHSZ - 1)]
                    call read_imgbatch( nptcls2update, pinds, batchlims)
                    !$omp parallel do default(shared) private(i,iptcl,ibatch) schedule(static) proc_bind(close)
                    do i=batchlims(1),batchlims(2)
                        iptcl  = pinds(i)
                        ibatch = i - batchlims(1) + 1
                        if( .not.fpls(ibatch)%does_exist() ) call fpls(ibatch)%new(build_glob%imgbatch(1), build_glob%spproj)
                        call build_glob%imgbatch(ibatch)%noise_norm(build_glob%lmsk, sdev_noise)
                        call build_glob%imgbatch(ibatch)%fft
                        ctfparms(ibatch) = build_glob%spproj%get_ctfparams(params_glob%oritype, iptcl)
                        call fpls(ibatch)%gen_planes(build_glob%imgbatch(ibatch), ctfparms(ibatch), iptcl=iptcl)
                    end do
                    !$omp end parallel do
                    ! gridding
                    do i=batchlims(1),batchlims(2)
                        iptcl       = pinds(i)
                        ibatch      = i - batchlims(1) + 1
                        call build_glob%spproj_field%get_ori(iptcl, orientation)
                        if( orientation%isstatezero() ) cycle
                        select case(trim(params_glob%refine))
                            case('clustersym')
                                ! always C1 reconstruction
                                call grid_ptcl(fpls(ibatch), c1_symop, orientation, s3D%o_peaks(iptcl))
                            case DEFAULT
                                call grid_ptcl(fpls(ibatch), build_glob%pgrpsyms, orientation, s3D%o_peaks(iptcl))
                        end select
                    end do
                end do
                ! normalise structure factors
                call norm_struct_facts( cline, which_iter)
                ! destruct
                call killrecvols()
                do ibatch=1,MAXIMGBATCHSZ
                    call fpls(ibatch)%kill
                end do
                deallocate(fpls,ctfparms)
       end select
       call orientation%kill
    end subroutine calc_3Drec

    subroutine setup_weights_read_o_peaks
        ! set npeaks
        npeaks = NPEAKS2REFINE
        ! particle weights
        select case(trim(params_glob%ptclw))
            case('yes')
                call build_glob%spproj_field%calc_soft_weights(params_glob%frac)
            case DEFAULT
                call build_glob%spproj_field%calc_hard_weights(params_glob%frac)
        end select
        ! prepare particle mask
        allocate(ptcl_mask(params_glob%fromp:params_glob%top))
        call build_glob%spproj_field%sample4update_and_incrcnt_nofrac([params_glob%fromp,params_glob%top],&
        nptcls2update, pinds, ptcl_mask)
        ! allocate s3D singleton
        call prep_strategy3D(ptcl_mask, npeaks)
        ! read peaks
        call read_o_peaks
    end subroutine setup_weights_read_o_peaks

    subroutine read_o_peaks
        use simple_strategy3D_utils, only: update_softmax_weights
        integer :: iptcl, n_nozero
        if( .not. file_exists(trim(params_glob%o_peaks_file)) )then
            THROW_HARD(trim(params_glob%o_peaks_file)//' file does not exist')
        endif
        call open_o_peaks_io(trim(params_glob%o_peaks_file))
        do iptcl=params_glob%fromp,params_glob%top
            if( ptcl_mask(iptcl) )then
                call read_o_peak(s3D%o_peaks(iptcl), [params_glob%fromp,params_glob%top], iptcl, n_nozero)
                call update_softmax_weights(iptcl, npeaks)
            endif
        end do
        call close_o_peaks_io
    end subroutine read_o_peaks

    subroutine calc_proj_weights
        real, allocatable :: weights(:), projs(:)
        integer :: i, ind, iptcl
        real    :: pw, proj_weights(params_glob%nspace), minw
        select case(params_glob%refine)
            case('cluster', 'snhc', 'clustersym', 'cont_single', 'eval')
                ! nothing to do
            case DEFAULT
                if( build_glob%spproj_field%get_avg('updatecnt') < 1.0 )then
                    ! nothing to do
                else
                    ! calculate the weight strenght per projection direction
                    proj_weights = 0.
                    do iptcl=params_glob%fromp,params_glob%top
                        pw = 1.0
                        if( build_glob%spproj_field%isthere(iptcl, 'w') ) pw = build_glob%spproj_field%get(iptcl, 'w')
                        if( s3D%o_peaks(iptcl)%isthere('ow') )then
                            weights = s3D%o_peaks(iptcl)%get_all('ow')
                            projs   = s3D%o_peaks(iptcl)%get_all('proj')
                            do i=1,size(projs)
                                ind = nint(projs(i))
                                if( weights(i) > TINY ) proj_weights(ind) = proj_weights(ind) + weights(i) * pw
                            end do
                            deallocate(weights, projs)
                        endif
                    end do
                    minw = minval(proj_weights, mask=proj_weights > TINY)
                    where( proj_weights < TINY ) proj_weights = minw ! to prevent division with zero
                endif
                call arr2file(proj_weights, params_glob%proj_weights_file)
        end select
    end subroutine calc_proj_weights

end module simple_strategy3D_matcher
