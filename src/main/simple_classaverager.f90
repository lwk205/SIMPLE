module simple_classaverager
include 'simple_lib.f08'
!$ use omp_lib
use simple_builder,      only: build_glob
use simple_parameters,   only: params_glob
use simple_ctf,          only: ctf
use simple_image,        only: image
implicit none

public :: cavger_new, cavger_transf_oridat, cavger_gen2Dclassdoc, cavger_assemble_sums,&
cavger_merge_eos_and_norm, cavger_calc_and_write_frcs_and_eoavg, cavger_write, cavger_read,&
cavger_readwrite_partial_sums, cavger_assemble_sums_from_parts, cavger_kill, cavgs_even, cavgs_odd, cavgs_merged
private
#include "simple_local_flags.inc"

type ptcl_record
    type(ctf)            :: tfun                                !< transfer function
    integer              :: pind    = 0                         !< particle index in stack
    integer              :: eo      = -1                        !< even is 0, odd is 1, default is -1
    real                 :: pw      = 0.0                       !< particle weight
    real                 :: dfx     = 0.0                       !< defocus in x (microns)
    real                 :: dfy     = 0.0                       !< defocus in y (microns)
    real                 :: angast  = 0.0                       !< angle of astigmatism (in degrees)
    real                 :: phshift = 0.0                       !< additional phase shift from the Volta
    integer, allocatable :: classes(:)                          !< class assignments
    integer, allocatable :: states(:)                           !< state assignments
    integer, allocatable :: eos(:)                              !< even/odd assignments
    integer, allocatable :: inpl_inds(:)                        !< in-plane rotation indices
    real,    allocatable :: ows(:)                              !< orientation weights
    real,    allocatable :: e3s(:)                              !< in-plane rotations
    real,    allocatable :: shifts(:,:)                         !< rotational origin shifts
end type ptcl_record

integer                        :: ctfflag                       !< ctf flag <yes=1|no=0|flip=2>
integer                        :: istart          = 0, iend = 0 !< particle index range
integer                        :: partsz          = 0           !< size of partition
integer                        :: ncls            = 0           !< # classes
integer                        :: filtsz          = 0           !< size of filter function or FSC
integer                        :: ldim(3)         = [0,0,0]     !< logical dimension of image
integer                        :: ldim_pd(3)      = [0,0,0]     !< logical dimension of image, padded
real                           :: smpd            = 0.          !< sampling distance
type(ptcl_record), allocatable :: precs(:)                      !< particle records
type(image),       allocatable :: cavgs_even(:)                 !< class averages
type(image),       allocatable :: cavgs_odd(:)                  !< -"-
type(image),       allocatable :: cavgs_merged(:)               !< -"-
type(image),       allocatable :: ctfsqsums_even(:)             !< CTF**2 sums for Wiener normalisation
type(image),       allocatable :: ctfsqsums_odd(:)              !< -"-
type(image),       allocatable :: ctfsqsums_merged(:)           !< -"-
integer,           allocatable :: prev_eo_pops(:,:)
logical,           allocatable :: pptcl_mask(:)
logical                        :: phaseplate    = .false.       !< Volta phaseplate images or not
logical                        :: l_is_class    = .true.        !< for prime2D or not
logical                        :: l_hard_assign = .true.        !< npeaks == 1 or not
logical                        :: l_bilinear    = .true.        !< whether to use bilinear or convolution interpolation
logical                        :: exists        = .false.       !< to flag instance existence

logical, parameter      :: L_BENCH      = .false.
integer(timer_int_kind) :: t_class_loop,t_batch_loop, t_gridding, t_init, t_tot
real(timer_int_kind)    :: rt_class_loop,rt_batch_loop, rt_gridding, rt_init, rt_tot
character(len=STDLEN)   :: benchfname

contains

    !>  \brief  is a constructor
    !!          data is now managed so that all exclusions are taken care of here
    !!          which means properly balanced batches can be produced for both soft
    !!          and hard clustering solutions
    subroutine cavger_new( which, ptcl_mask )
        character(len=*),      intent(in)    :: which !< class/proj
        logical, optional,     intent(in)    :: ptcl_mask(params_glob%fromp:params_glob%top)
        integer :: alloc_stat, icls
        ! destruct possibly pre-existing instance
        call cavger_kill
        if( present(ptcl_mask) )then
            allocate(pptcl_mask(params_glob%fromp:params_glob%top), source=ptcl_mask)
        else
            allocate(pptcl_mask(params_glob%fromp:params_glob%top), source=.true.)
        endif
        ! class or proj
        select case(which)
            case('class')
                l_is_class = .true.
                ncls       = params_glob%ncls
            case('proj')
                l_is_class = .false.
                ! possible reduction of # projection directions used
                ! for the class average representation
                ncls = min(NSPACE_REDUCED,params_glob%nspace)
            case DEFAULT
                THROW_HARD('unsupported which flag')
        end select
        ! work out range and partsz
        if( params_glob%l_distr_exec )then
            istart = params_glob%fromp
            iend   = params_glob%top
        else
            istart = 1
            iend   = params_glob%nptcls
        endif
        partsz     = count(pptcl_mask)
        ! CTF logics
        ctfflag    = build_glob%spproj%get_ctfflag_type('ptcl2D')
        ! set phaseplate flag
        phaseplate = build_glob%spproj%has_phaseplate('ptcl2D')
        ! smpd
        smpd       = params_glob%smpd
        ! set ldims
        ldim       = [params_glob%box,params_glob%box,1]
        ldim_pd    = [params_glob%boxpd,params_glob%boxpd,1]
        ldim_pd(3) = 1
        filtsz     = build_glob%img%get_filtsz()
        ! build arrays
        allocate(precs(partsz), cavgs_even(ncls), cavgs_odd(ncls),&
        &cavgs_merged(ncls), ctfsqsums_even(ncls),&
        &ctfsqsums_odd(ncls), ctfsqsums_merged(ncls), prev_eo_pops(ncls,2), stat=alloc_stat)
        if(alloc_stat .ne. 0)call allocchk('cavger_new; simple_classaverager', alloc_stat)
        prev_eo_pops = 0
        !$omp parallel do default(shared) private(icls) schedule(static) proc_bind(close)
        do icls=1,ncls
            call cavgs_even(icls)%new(ldim_pd,params_glob%smpd,wthreads=.false.)
            call cavgs_odd(icls)%new(ldim_pd,params_glob%smpd,wthreads=.false.)
            call cavgs_merged(icls)%new(ldim_pd,params_glob%smpd,wthreads=.false.)
            call ctfsqsums_even(icls)%new(ldim_pd,params_glob%smpd,wthreads=.false.)
            call ctfsqsums_odd(icls)%new(ldim_pd,params_glob%smpd,wthreads=.false.)
            call ctfsqsums_merged(icls)%new(ldim_pd,params_glob%smpd,wthreads=.false.)
        end do
        !$omp end parallel do
        ! flag existence
        exists = .true.
    end subroutine cavger_new

    ! setters/getters

    !>  \brief  transfers orientation data to the instance
    subroutine cavger_transf_oridat( spproj )
        use simple_sp_project, only: sp_project
        class(sp_project), intent(inout) :: spproj
        type(ctfparams)   :: ctfvars(nthr_glob)
        integer           :: i, icls, alloc_stat, cnt, iptcl, ithr
        ! build index map
        cnt = 0
        do iptcl=istart,iend
            if(.not.pptcl_mask(iptcl)) cycle
            cnt = cnt + 1
            ! exclusion
            precs(cnt)%pind = 0
            if( spproj%os_ptcl2D%get_state(iptcl) == 0 ) cycle
            if( spproj%os_ptcl2D%get(iptcl,'w') < TINY ) cycle
            precs(cnt)%pind = iptcl
        enddo
        ! fetch data from project
        !$omp parallel do default(shared) private(cnt,iptcl,ithr) schedule(static) proc_bind(close)
        do cnt = 1,partsz
            iptcl = precs(cnt)%pind
            if( iptcl == 0 ) cycle
            ithr  = omp_get_thread_num() + 1
            precs(cnt)%eo      = nint(spproj%os_ptcl2D%get(iptcl,'eo'))
            precs(cnt)%pw      = spproj%os_ptcl2D%get(iptcl,'w')
            ctfvars(ithr)      = spproj%get_ctfparams('ptcl2D',iptcl)
            precs(cnt)%tfun    = ctf(params_glob%smpd, ctfvars(ithr)%kv, ctfvars(ithr)%cs, ctfvars(ithr)%fraca)
            precs(cnt)%dfx     = ctfvars(ithr)%dfx
            precs(cnt)%dfy     = ctfvars(ithr)%dfy
            precs(cnt)%angast  = ctfvars(ithr)%angast
            precs(cnt)%phshift = 0.
            if( phaseplate ) precs(cnt)%phshift = ctfvars(ithr)%phshift
            ! allocate & set info in record
            if( allocated(precs(cnt)%classes)  )  deallocate(precs(cnt)%classes)
            if( allocated(precs(cnt)%inpl_inds))  deallocate(precs(cnt)%inpl_inds)
            if( allocated(precs(cnt)%states)   )  deallocate(precs(cnt)%states)
            if( allocated(precs(cnt)%eos)      )  deallocate(precs(cnt)%eos)
            if( allocated(precs(cnt)%ows)      )  deallocate(precs(cnt)%ows)
            if( allocated(precs(cnt)%e3s)      )  deallocate(precs(cnt)%e3s)
            if( allocated(precs(cnt)%shifts)   )  deallocate(precs(cnt)%shifts)
            allocate( precs(cnt)%classes(1),  precs(cnt)%states(1),    precs(cnt)%ows(1), precs(cnt)%e3s(1),&
                     &precs(cnt)%shifts(1,2), precs(cnt)%inpl_inds(1), precs(cnt)%eos(1), stat=alloc_stat )
            precs(cnt)%classes(1)   = nint(spproj%os_ptcl2D%get(iptcl, 'class'))
            precs(cnt)%inpl_inds(1) = nint(spproj%os_ptcl2D%get(iptcl, 'inpl'))
            precs(cnt)%states(1)    = nint(spproj%os_ptcl2D%get(iptcl, 'state'))
            precs(cnt)%eos(1)       = nint(spproj%os_ptcl2D%get(iptcl, 'eo'))
            precs(cnt)%ows(1)       = spproj%os_ptcl2D%get(iptcl, 'w')
            precs(cnt)%e3s(1)       = spproj%os_ptcl2D%e3get(iptcl)
            precs(cnt)%shifts(1,:)  = spproj%os_ptcl2D%get_2Dshift(iptcl)
        end do
        !$omp end parallel do
        l_hard_assign = .true.
        prev_eo_pops = 0
        if( trim(params_glob%stream).eq.'yes' .and. spproj%os_cls2D%get_noris() == ncls )then
            do i = 1,ncls
                icls = nint(spproj%os_cls2D%get(i,'class'))
                if( .not.spproj%os_cls2D%isthere(i,'pop_even') ) cycle
                prev_eo_pops(icls,1) = nint(spproj%os_cls2D%get(i,'pop_even'))
                prev_eo_pops(icls,2) = nint(spproj%os_cls2D%get(i,'pop_odd'))
            enddo
        endif
    end subroutine cavger_transf_oridat

    !>  \brief prepares a 2D class document with class index, resolution,
    !!         poulation, average correlation and weight
    subroutine cavger_gen2Dclassdoc( spproj )
        use simple_sp_project, only: sp_project
        class(sp_project), intent(inout) :: spproj
        integer  :: pops(params_glob%ncls)
        real(dp) :: corrs(params_glob%ncls), ws(params_glob%ncls), specscores(params_glob%ncls)
        real     :: frc05, frc0143, rstate
        integer  :: i, iptcl, icls, pop, nptcls
        nptcls     = spproj%os_ptcl2D%get_noris()
        pops       = 0
        corrs      = 0.d0
        ws         = 0.d0
        specscores = 0.d0
        !$omp parallel do default(shared) private(iptcl,rstate,icls) schedule(static)&
        !$omp proc_bind(close) reduction(+:pops,corrs,ws,specscores)
        do iptcl=1,nptcls
            rstate = spproj%os_ptcl2D%get(iptcl,'state')
            if( rstate < 0.5 )cycle
            icls = nint(spproj%os_ptcl2D%get(iptcl,'class'))
            if( icls<1 .or. icls>params_glob%ncls )cycle
            pops(icls)       = pops(icls)      + 1
            corrs(icls)      = corrs(icls)     + spproj%os_ptcl2D%get(iptcl,'corr')
            ws(icls)         = ws(icls)        + spproj%os_ptcl2D%get(iptcl,'w')
            specscores(icls) = specscores(icls)+ spproj%os_ptcl2D%get(iptcl,'specscore')
        enddo
        !$omp end parallel do
        if( trim(params_glob%stream).eq.'yes'  .and.&
            &spproj%os_cls2D%get_noris()==ncls .and. params_glob%update_frac<.99 )then
            do i = 1,ncls
                icls = nint(spproj%os_cls2D%get(i,'class'))
                if( .not.spproj%os_cls2D%isthere(i,'pop_even') ) cycle
                prev_eo_pops(icls,1) = nint(spproj%os_cls2D%get(i,'pop_even'))
                prev_eo_pops(icls,2) = nint(spproj%os_cls2D%get(i,'pop_odd'))
                pop = sum(prev_eo_pops(icls,:))
                if( pop == 0 ) cycle
                corrs(icls)      = corrs(icls)      + real(pop) * spproj%os_cls2D%get(i,'corr')
                ws(icls)         = ws(icls)         + real(pop) * spproj%os_cls2D%get(i,'ws')
                specscores(icls) = specscores(icls) + real(pop) * spproj%os_cls2D%get(i,'specscore')
                pops(icls)       = pops(icls) + pop
            enddo
        endif
        where(pops>1)
            corrs      = corrs / real(pops)
            ws         = ws / real(pops)
            specscores = specscores / real(pops)
        elsewhere
            corrs      = -1.
            ws         = 0.
            specscores = 0.
        end where
        call spproj%os_cls2D%new( params_glob%ncls )
        do icls=1,params_glob%ncls
            pop = pops(icls)
            call build_glob%projfrcs%estimate_res(icls, frc05, frc0143)
            call spproj%os_cls2D%set(icls, 'class',     real(icls))
            call spproj%os_cls2D%set(icls, 'pop',       real(pop))
            call spproj%os_cls2D%set(icls, 'res',       frc0143)
            call spproj%os_cls2D%set(icls, 'corr',      real(corrs(icls)))
            call spproj%os_cls2D%set(icls, 'w',         real(ws(icls)))
            call spproj%os_cls2D%set(icls, 'specscore', real(specscores(icls)))
            if( pop > 0 )then
                call spproj%os_cls2D%set(icls, 'state', 1.0) ! needs to be default val if no selection has been done
            else
                call spproj%os_cls2D%set(icls, 'state', 0.0) ! exclusion
            endif
        end do
    end subroutine cavger_gen2Dclassdoc

    !>  \brief  is for initialization of the sums
    subroutine init_cavgs_sums
        integer :: icls
        !$omp parallel do default(shared) private(icls) schedule(static) proc_bind(close)
        do icls=1,ncls
            call cavgs_even(icls)%new(ldim_pd,smpd,wthreads=.false.)
            call cavgs_odd(icls)%new(ldim_pd,smpd,wthreads=.false.)
            call cavgs_merged(icls)%new(ldim_pd,smpd,wthreads=.false.)
            call cavgs_even(icls)%zero_and_flag_ft
            call cavgs_odd(icls)%zero_and_flag_ft
            call cavgs_merged(icls)%zero_and_flag_ft
            call ctfsqsums_even(icls)%zero_and_flag_ft
            call ctfsqsums_odd(icls)%zero_and_flag_ft
            call ctfsqsums_merged(icls)%zero_and_flag_ft
        end do
        !$omp end parallel do
    end subroutine init_cavgs_sums

    !>  \brief  is for getting allocatable arrays with particle/record/ori indices
    subroutine get_indices( class, pinds, iprecs, ioris )
        integer,              intent(in)  :: class
        integer, allocatable, intent(out) :: pinds(:)
        integer, allocatable, intent(out) :: iprecs(:)
        integer, allocatable, intent(out) :: ioris(:)
        integer :: pop, alloc_stat, i, sz, iprec, cnt
        logical, allocatable :: l_state_class(:)
        pop = class_pop(class)
        if( allocated(pinds) )  deallocate(pinds)
        if( allocated(iprecs) ) deallocate(iprecs)
        if( allocated(ioris)  ) deallocate(ioris)
        allocate(pinds(pop), iprecs(pop), ioris(pop), stat=alloc_stat)
        if(alloc_stat .ne. 0)call allocchk('get_iprecs_ioris; simple_classaverager', alloc_stat)
        cnt = 0
        do iprec=1,partsz
            if( allocated(precs(iprec)%classes) )then
                sz = size(precs(iprec)%classes)
                allocate(l_state_class(sz))
                where( precs(iprec)%states > 0 .and. precs(iprec)%classes .eq. class )
                    l_state_class = .true.
                else where
                    l_state_class = .false.
                endwhere
                if( any(l_state_class) )then
                    do i=1,sz
                        if( l_state_class(i) )then
                            cnt = cnt + 1
                            pinds(cnt)  = precs(iprec)%pind
                            iprecs(cnt) = iprec
                            ioris(cnt)  = i
                        endif
                    enddo
                endif
                deallocate(l_state_class)
            endif
        end do
    end subroutine get_indices

    !>  \brief  is for calculating class population
    integer function class_pop( class )
        integer, intent(in) :: class
        class_pop = sum(eo_class_pop(class))
    end function class_pop

    !>  \brief  is for calculating even/odd class population
    function eo_class_pop( class ) result( pops )
        integer, intent(in) :: class
        integer :: pops(2), iprec, sz
        logical, allocatable :: l_state_class(:)
        pops = 0
        do iprec=1,partsz
            if( allocated(precs(iprec)%classes) )then
                sz = size(precs(iprec)%classes)
                allocate(l_state_class(sz))
                where( precs(iprec)%states > 0 .and. precs(iprec)%classes .eq. class )
                    l_state_class = .true.
                else where
                    l_state_class = .false.
                endwhere
                if( precs(iprec)%eo == 1 )then
                    pops(2) = pops(2) + count(l_state_class)
                else
                    pops(1) = pops(1) + count(l_state_class)
                endif
                deallocate(l_state_class)
            endif
        end do
    end function eo_class_pop

    ! calculators

    !>  \brief  is for assembling the sums in distributed/non-distributed mode
    !!          using gridding interpolation in Fourier space
    subroutine cavger_assemble_sums( do_frac_update )
        use simple_kbinterpol,          only: kbinterpol
        use simple_strategy2D3D_common, only: read_img
        logical,      intent(in) :: do_frac_update
        type(kbinterpol)         :: kbwin
        type(image)              :: cls_imgsum_even, cls_imgsum_odd
        type(image), allocatable :: batch_imgs(:), cgrid_imgs(:)
        complex,     allocatable :: cmat_even(:,:,:), cmat_odd(:,:,:)
        real,        allocatable :: rho(:,:), rho_even(:,:), rho_odd(:,:), w(:,:)
        integer,     allocatable :: ptcls_inds(:), batches(:,:), iprecs(:)
        integer,     allocatable :: ioris(:), cyc1(:), cyc2(:)
        complex,     parameter   :: zero = cmplx(0.,0.)
        complex :: fcomp
        real    :: loc(2), mat(2,2), dist(2), pw, add_phshift
        integer :: lims(3,2), phys_cmat(3), win_corner(2), cyc_limsR(2,2),cyc_lims(3,2)
        integer :: cnt_progress, nbatches, batch, icls_pop, iprec, iori, i, batchsz, fnr, sh, iwinsz, nyq
        integer :: alloc_stat, wdim, h, k, l, m, ll, mm, incr, icls, iptcl, batchsz_max, interp_shlim, interp_shlim_sq
        if( .not. params_glob%l_distr_exec ) write(logfhandle,'(a)') '>>> ASSEMBLING CLASS SUMS'
        if( l_BENCH )then
            rt_tot = 0.
            t_tot  = tic()
            t_init = t_tot
        endif
        ! init cavgs
        call init_cavgs_sums
        if( do_frac_update )then
            call cavger_readwrite_partial_sums( 'read' )
            call cavger_apply_weights( 1. - params_glob%update_frac )
        endif
        kbwin  = kbinterpol(KBWINSZ, params_glob%alpha)
        wdim   = kbwin%get_wdim()
        iwinsz = ceiling(kbwin%get_winsz() - 0.5)
        incr   = 0
        ! determines max batch size
        batchsz_max = 0
        ! class loop
        do icls=1,ncls
            ! batch planning
            icls_pop = class_pop(icls)
            if( icls_pop < 1 ) cycle
            nbatches = ceiling(real(icls_pop)/real(params_glob%nthr*BATCHTHRSZ))
            batches  = split_nobjs_even(icls_pop, nbatches)
            ! batch loop
            do batch=1,nbatches
                ! prep batch
                batchsz = batches(batch,2) - batches(batch,1) + 1
                if( batchsz > batchsz_max ) batchsz_max = batchsz
            end do
        end do
        if( allocated(batches) ) deallocate(batches)
        ! pre-allocations
        allocate(batch_imgs(batchsz_max), cgrid_imgs(batchsz_max),&
                &cyc1(wdim), cyc2(wdim), w(wdim, wdim))
        do i=1,batchsz_max
            call batch_imgs(i)%new(ldim, params_glob%smpd,    wthreads=.false.)
            call cgrid_imgs(i)%new(ldim_pd, params_glob%smpd, wthreads=.false.)
        end do
        ! limits
        lims       = cgrid_imgs(1)%loop_lims(2)
        cyc_lims   = cgrid_imgs(1)%loop_lims(3)
        cmat_even  = cgrid_imgs(1)%get_cmat()
        cmat_odd   = cgrid_imgs(1)%get_cmat()
        nyq        = cgrid_imgs(1)%get_lfny(1)
        interp_shlim    = nyq+1
        interp_shlim_sq = interp_shlim**2
        cyc_limsR(:,1) = cyc_lims(1,:)  ! limits in fortran layered format
        cyc_limsR(:,2) = cyc_lims(2,:)  ! to avoid copy on cyci_1d call
        allocate( rho(lims(1,1):lims(1,2),lims(2,1):lims(2,2)),&
                 &rho_even(lims(1,1):lims(1,2),lims(2,1):lims(2,2)),&
                 &rho_odd( lims(1,1):lims(1,2),lims(2,1):lims(2,2)), stat=alloc_stat)
        if( L_BENCH )then
            rt_class_loop = 0.
            rt_batch_loop = 0.
            rt_gridding   = 0.
            rt_init       = toc(t_init)
        endif
        cnt_progress = 0
        ! class loop
        do icls=1,ncls
            if( L_BENCH ) t_class_loop = tic()
            cnt_progress = cnt_progress + 1
            call progress(cnt_progress, ncls)
            icls_pop = class_pop(icls)
            if( icls_pop == 0 ) cycle
            call get_indices(icls, ptcls_inds, iprecs, ioris)
            ! class temporary matrices
            cmat_even = zero
            cmat_odd  = zero
            rho       = 0.
            rho_even  = 0.
            rho_odd   = 0.
            ! batch planning
            nbatches = ceiling(real(icls_pop)/real(params_glob%nthr*BATCHTHRSZ))
            batches  = split_nobjs_even(icls_pop, nbatches)
            if( L_BENCH ) rt_class_loop = rt_class_loop + toc(t_class_loop)
            ! batch loop, prep
            do batch=1,nbatches
                ! prep batch
                batchsz = batches(batch,2) - batches(batch,1) + 1
                ! read images
                if( L_BENCH ) t_batch_loop = tic()
                do i=1,batchsz
                    iptcl = ptcls_inds(batches(batch,1) + i - 1)
                    call read_img( iptcl, batch_imgs(i) )
                enddo
                ! batch particles loop
                if( L_BENCH ) rt_batch_loop = rt_batch_loop + toc(t_batch_loop)
                if( L_BENCH ) t_gridding = tic()
                !$omp parallel do default(shared) schedule(static) reduction(+:cmat_even,cmat_odd,rho_even,rho_odd) proc_bind(close)&
                !$omp private(iptcl,fcomp,win_corner,i,iprec,iori,add_phshift,rho,pw,mat,h,k,l,m,ll,mm,dist,loc,sh,phys_cmat,cyc1,cyc2,w,incr)
                ! batch loop, direct Fourier interpolation
                do i=1,batchsz
                    iptcl = ptcls_inds(batches(batch,1) + i - 1)
                    iprec = iprecs(batches(batch,1) + i - 1)
                    iori  = ioris(batches(batch,1) + i - 1)
                    ! normalize & pad & FFT
                    call batch_imgs(i)%noise_norm_pad_fft(build_glob%lmsk, cgrid_imgs(i))
                    ! apply CTF, shift
                    add_phshift = 0.
                    if( phaseplate ) add_phshift = precs(iprec)%phshift
                    if( ctfflag /= CTFFLAG_NO )then
                        if( ctfflag == CTFFLAG_FLIP )then
                            call precs(iprec)%tfun%apply_and_shift(cgrid_imgs(i), 1, lims, rho, -precs(iprec)%shifts(iori,1),&
                            &-precs(iprec)%shifts(iori,2), precs(iprec)%dfx, precs(iprec)%dfy, precs(iprec)%angast, add_phshift)
                        else
                            call precs(iprec)%tfun%apply_and_shift(cgrid_imgs(i), 2, lims, rho, -precs(iprec)%shifts(iori,1),&
                            &-precs(iprec)%shifts(iori,2), precs(iprec)%dfx, precs(iprec)%dfy, precs(iprec)%angast, add_phshift)
                        endif
                    else
                        call precs(iprec)%tfun%apply_and_shift(cgrid_imgs(i), 3, lims, rho, -precs(iprec)%shifts(iori,1),&
                        &-precs(iprec)%shifts(iori,2), precs(iprec)%dfx, precs(iprec)%dfy, precs(iprec)%angast, add_phshift)
                    endif
                    ! prep weight
                    if( l_hard_assign )then
                        pw = precs(iprec)%pw
                    else
                        pw = precs(iprec)%pw * precs(iprec)%ows(iori)
                    endif
                    ! sampling density update
                    select case(precs(iprec)%eo)
                        case(0,-1)
                            rho_even = rho_even + pw * rho
                        case(1)
                            rho_odd  = rho_odd + pw * rho
                    end select
                    ! rotation
                    call rotmat2d(-precs(iprec)%e3s(iori), mat)
                    ! Interpolation
                    if( l_bilinear )then
                        ! bi-linear interpolation
                        do h=lims(1,1),lims(1,2)
                            do k=lims(2,1),lims(2,2)
                                sh = nint(hyp(real(h),real(k)))
                                if( sh > interp_shlim )cycle
                                loc = matmul(real([h,k]),mat)
                                ! interpolation
                                win_corner = floor(loc) ! bottom left corner
                                dist  = loc - real(win_corner)
                                l     = cyci_1d(cyc_limsR(:,1), win_corner(1))
                                ll    = cyci_1d(cyc_limsR(:,1), win_corner(1)+1)
                                m     = cyci_1d(cyc_limsR(:,2), win_corner(2))
                                mm    = cyci_1d(cyc_limsR(:,2), win_corner(2)+1)
                                fcomp =         (1.-dist(1))*(1.-dist(2)) * cgrid_imgs(i)%get_fcomp2D(l, m)  ! bottom left corner
                                fcomp = fcomp + (1.-dist(1))*dist(2)      * cgrid_imgs(i)%get_fcomp2D(l, mm) ! bottom right corner
                                fcomp = fcomp + dist(1)*(1.-dist(2))      * cgrid_imgs(i)%get_fcomp2D(ll,m)  ! upper left corner
                                fcomp = fcomp + dist(1)*dist(2)           * cgrid_imgs(i)%get_fcomp2D(ll,mm) ! upper right corner
                                ! addition
                                phys_cmat = cgrid_imgs(i)%comp_addr_phys([h,k,0])
                                select case(precs(iprec)%eo)
                                    case(0,-1)
                                        cmat_even(phys_cmat(1),phys_cmat(2),1) = cmat_even(phys_cmat(1),phys_cmat(2),1) + pw*fcomp
                                    case(1)
                                        cmat_odd(phys_cmat(1),phys_cmat(2),1)  = cmat_odd(phys_cmat(1),phys_cmat(2),1)  + pw*fcomp
                                end select
                            end do
                        end do
                    else
                        ! convolution interpolation
                        do h=lims(1,1),lims(1,2)
                            do k=lims(2,1),lims(2,2)
                                sh = nint(hyp(real(h),real(k)))
                                if( sh > interp_shlim )cycle
                                loc = matmul(real([h,k]),mat)
                                win_corner = nint(loc) - iwinsz
                                ! weights kernel
                                w = 1.
                                do l=1,wdim
                                    incr = l - 1
                                    ! circular addresses
                                    cyc1(l) = cyci_1d(cyc_limsR(:,1), win_corner(1) + incr)
                                    cyc2(l) = cyci_1d(cyc_limsR(:,2), win_corner(2) + incr)
                                    ! interpolation kernel matrix
                                    w(l,:) = w(l,:) * kbwin%apod( real(win_corner(1) + incr) - loc(1) )
                                    w(:,l) = w(:,l) * kbwin%apod( real(win_corner(2) + incr) - loc(2) )
                                enddo
                                w = pw * w / sum(w)
                                ! interpolation
                                fcomp = zero
                                do l=1,wdim
                                    do m=1,wdim
                                        if( w(l,m) < TINY ) cycle
                                        fcomp = fcomp + cgrid_imgs(i)%get_fcomp2D(cyc1(l),cyc2(m)) * w(l,m)
                                    end do
                                end do
                                ! addition
                                phys_cmat = cgrid_imgs(i)%comp_addr_phys([h,k,0])
                                select case(precs(iprec)%eo)
                                case(0,-1)
                                    cmat_even(phys_cmat(1),phys_cmat(2),1) = cmat_even(phys_cmat(1),phys_cmat(2),1) + fcomp
                                case(1)
                                    cmat_odd(phys_cmat(1),phys_cmat(2),1) = cmat_odd(phys_cmat(1),phys_cmat(2),1) + fcomp
                                end select
                            end do
                        end do
                    endif
                enddo
                !$omp end parallel do
                if( L_BENCH ) rt_gridding = rt_gridding + toc(t_gridding)
            enddo ! batch loop
            if( L_BENCH ) t_class_loop = tic()
            ! put back cmats
            call cls_imgsum_even%new(ldim_pd, params_glob%smpd)
            call cls_imgsum_odd%new(ldim_pd, params_glob%smpd)
            call cls_imgsum_even%set_cmat(cmat_even)
            call cls_imgsum_odd%set_cmat(cmat_odd)
            ! updates cavgs & rhos
            if( do_frac_update )then
                call cavgs_even(icls)%add_cmats_to_cmats(cavgs_odd(icls), ctfsqsums_even(icls), ctfsqsums_odd(icls),&
                    &cls_imgsum_even,cls_imgsum_odd, lims, rho_even, rho_odd)
            else
                call cavgs_even(icls)%set_cmats_from_cmats(cavgs_odd(icls), ctfsqsums_even(icls), ctfsqsums_odd(icls),&
                    &cls_imgsum_even,cls_imgsum_odd, lims, rho_even, rho_odd)
            endif
            deallocate(ptcls_inds, batches, iprecs, ioris)
            if( L_BENCH ) rt_class_loop = rt_class_loop + toc(t_class_loop)
        enddo ! class loop
        ! batch cleanup
        call cls_imgsum_even%kill
        call cls_imgsum_odd%kill
        do i=1,batchsz_max
            call batch_imgs(i)%kill
            call cgrid_imgs(i)%kill
        enddo
        if( allocated(cmat_even) ) deallocate(cmat_even)
        if( allocated(cmat_odd)  ) deallocate(cmat_odd)
        deallocate(rho, rho_even, rho_odd, batch_imgs, cgrid_imgs, cyc1, cyc2, w)
        if( .not. params_glob%l_distr_exec ) call cavger_merge_eos_and_norm
        if( L_BENCH )then
            rt_tot = rt_tot + toc(t_tot)
            benchfname = 'CLASSAVERAGER_BENCH_'//int2str_pad(max(1,params_glob%startit),4)//'_'//int2str_pad(params_glob%part,2)//'.txt'
            call fopen(fnr, FILE=trim(benchfname), STATUS='REPLACE', action='WRITE')
            write(fnr,'(a)') '*** TIMINGS (s) ***'
            write(fnr,'(a,1x,f9.2)') 'init       : ', rt_init
            write(fnr,'(a,1x,f9.2)') 'class loop : ', rt_class_loop
            write(fnr,'(a,1x,f9.2)') 'batch loop : ', rt_batch_loop
            write(fnr,'(a,1x,f9.2)') 'gridding   : ', rt_gridding
            write(fnr,'(a,1x,f9.2)') 'total time : ', rt_tot
            write(fnr,'(a)') ''
            write(fnr,'(a)') '*** RELATIVE TIMINGS (%) ***'
            write(fnr,'(a,1x,f9.2)') 'batch loop : ', (rt_init/rt_tot)       * 100.
            write(fnr,'(a,1x,f9.2)') 'gridding   : ', (rt_class_loop/rt_tot) * 100.
            write(fnr,'(a,1x,f9.2)') 'batch loop : ', (rt_batch_loop/rt_tot) * 100.
            write(fnr,'(a,1x,f9.2)') 'gridding   : ', (rt_gridding/rt_tot)   * 100.
            call fclose(fnr)
        endif
    end subroutine cavger_assemble_sums

    !>  \brief  merges the even/odd pairs and normalises the sums
    subroutine cavger_merge_eos_and_norm
        type(image) :: gridcorrection_img
        integer     :: icls, eo_pop(2), pop
        call cavger_prep_gridding_correction(gridcorrection_img)
        !$omp parallel do default(shared) private(icls,eo_pop,pop) schedule(static) proc_bind(close)
        do icls=1,ncls
            eo_pop = prev_eo_pops(icls,:) + eo_class_pop(icls)
            pop    = sum(eo_pop)
            if(pop == 0)then
                call cavgs_merged(icls)%zero_and_unflag_ft
                call cavgs_even(icls)%zero_and_unflag_ft
                call cavgs_odd(icls)%zero_and_unflag_ft
                call ctfsqsums_merged(icls)%zero_and_flag_ft
            else
                call cavgs_merged(icls)%zero_and_flag_ft
                call cavgs_merged(icls)%add(cavgs_even(icls))
                call cavgs_merged(icls)%add(cavgs_odd(icls))
                call ctfsqsums_merged(icls)%zero_and_flag_ft
                call ctfsqsums_merged(icls)%add(ctfsqsums_even(icls))
                call ctfsqsums_merged(icls)%add(ctfsqsums_odd(icls))
                ! (w*CTF)**2 density correction
                if(eo_pop(1) > 1) call cavgs_even(icls)%ctf_dens_correct(ctfsqsums_even(icls))
                if(eo_pop(2) > 1) call cavgs_odd(icls)%ctf_dens_correct(ctfsqsums_odd(icls))
                if(pop > 1)       call cavgs_merged(icls)%ctf_dens_correct(ctfsqsums_merged(icls))
                call cavgs_even(icls)%ifft()
                call cavgs_odd(icls)%ifft()
                call cavgs_merged(icls)%ifft()
            endif
            call cavgs_even(icls)%clip_inplace(ldim)
            call cavgs_odd(icls)%clip_inplace(ldim)
            call cavgs_merged(icls)%clip_inplace(ldim)
            ! gridding correction
            call cavgs_even(icls)%div(gridcorrection_img)
            call cavgs_odd(icls)%div(gridcorrection_img)
            call cavgs_merged(icls)%div(gridcorrection_img)
        end do
        !$omp end parallel do
        call gridcorrection_img%kill
    end subroutine cavger_merge_eos_and_norm

    !>  \brief  calculates Fourier ring correlations
    subroutine cavger_calc_and_write_frcs_and_eoavg( fname )
        character(len=*), intent(in) :: fname
        type(image), allocatable     :: even_imgs(:), odd_imgs(:)
        real,        allocatable     :: frc(:)
        integer :: icls, find, find_plate
        allocate(even_imgs(ncls), odd_imgs(ncls), frc(filtsz))
        do icls=1,ncls
            call even_imgs(icls)%copy(cavgs_even(icls))
            call odd_imgs(icls)%copy(cavgs_odd(icls))
        end do
        !$omp parallel do default(shared) private(icls,frc,find,find_plate) schedule(static) proc_bind(close)
        do icls=1,ncls
            if( params_glob%l_innermsk )then
                call even_imgs(icls)%mask(params_glob%msk, 'soft', inner=params_glob%inner, width=params_glob%width)
                call odd_imgs(icls)%mask(params_glob%msk, 'soft', inner=params_glob%inner, width=params_glob%width)
            else
                call even_imgs(icls)%mask(params_glob%msk, 'soft')
                call odd_imgs(icls)%mask(params_glob%msk, 'soft')
            endif
            call even_imgs(icls)%fft()
            call odd_imgs(icls)%fft()
            call even_imgs(icls)%fsc(odd_imgs(icls), frc)
            find_plate = 0
            if( phaseplate ) call phaseplate_correct_fsc(frc, find_plate)
            call build_glob%projfrcs%set_frc(icls, frc, 1)
            ! average low-resolution info between eo pairs to keep things in register
            find = build_glob%projfrcs%estimate_find_for_eoavg(icls, 1)
            find = max(find, find_plate)
            call cavgs_merged(icls)%fft()
            call cavgs_even(icls)%fft()
            call cavgs_odd(icls)%fft()
            call cavgs_even(icls)%insert_lowres_serial(cavgs_merged(icls), find)
            call cavgs_odd(icls)%insert_lowres_serial(cavgs_merged(icls), find)
            call cavgs_merged(icls)%ifft()
            call cavgs_even(icls)%ifft()
            call cavgs_odd(icls)%ifft()
        end do
        !$omp end parallel do
        ! write FRCs
        call build_glob%projfrcs%write(fname)
        ! SSNR
        call cavger_calc_and_write_pssnr
        ! destruct
        do icls=1,ncls
            call even_imgs(icls)%kill
            call odd_imgs(icls)%kill
        end do
        deallocate(even_imgs, odd_imgs, frc)
    end subroutine cavger_calc_and_write_frcs_and_eoavg

    subroutine cavger_calc_and_write_pssnr
        use simple_estimate_ssnr, only: subsample_filter, fsc2ssnr
        real, allocatable :: pad_inv_ctfsq_avg(:), frc(:), inv_ctfsq_avg(:), ssnr(:)
        real              :: ratio
        integer           :: icls
        allocate(inv_ctfsq_avg(filtsz),frc(filtsz),ssnr(filtsz))
        ratio = real(params_glob%box**2) / (PI*params_glob%msk**2.) ! for ssnr of spherically masked particle image
        !$omp parallel do default(shared) private(icls,pad_inv_ctfsq_avg,frc,inv_ctfsq_avg,ssnr)&
        !$omp schedule(static) proc_bind(close)
        do icls=1,ncls
            call ctfsqsums_merged(icls)%spectrum('real', pad_inv_ctfsq_avg, norm=.true.)
            pad_inv_ctfsq_avg = 1. / pad_inv_ctfsq_avg
            call subsample_filter(size(pad_inv_ctfsq_avg),filtsz, pad_inv_ctfsq_avg, inv_ctfsq_avg)
            frc = build_glob%projfrcs%get_frc(icls, params_glob%box, 1)
            ! Eq 19, Sindelar et al., JSB, 2011
            ssnr = ratio * inv_ctfsq_avg * fsc2ssnr(frc)
            call build_glob%projpssnrs%set_frc(icls, ssnr, 1)
        end do
        !$omp end parallel do
        ! write PSSNRs
        call build_glob%projpssnrs%write(trim(PSSNR_FBODY)//int2str_pad(1,2)//BIN_EXT)
    end subroutine cavger_calc_and_write_pssnr

    ! I/O

    !>  \brief  writes class averages to disk
    subroutine cavger_write( fname, which )
        character(len=*),  intent(in) :: fname, which
        integer               :: icls
        select case(which)
            case('even')
                do icls=1,ncls
                    call cavgs_even(icls)%write(fname, icls)
                end do
            case('odd')
                do icls=1,ncls
                    call cavgs_odd(icls)%write(fname, icls)
                end do
            case('merged')
                 do icls=1,ncls
                    call cavgs_merged(icls)%write(fname, icls)
                end do
            case DEFAULT
                THROW_HARD('unsupported which flag')
        end select
        call update_stats

    contains

        subroutine update_stats
            integer :: icls, cnt
            real    :: stats(4),minv,maxv,meanv,stdevv
            logical :: l_err
            stats(1)   = huge(stats(1))
            stats(2)   = -stats(1)
            stats(3:4) = 0.
            cnt        = 1
            do icls = 1,ncls
                select case(which)
                    case('even')
                        call cavgs_even(icls)%stats(meanv, stdevv, maxv, minv, errout=l_err)
                    case('odd')
                        call cavgs_odd(icls)%stats(meanv, stdevv, maxv, minv, errout=l_err)
                    case('merged')
                        call cavgs_merged(icls)%stats(meanv, stdevv, maxv, minv, errout=l_err)
                end select
                if( .not.l_err )then
                    cnt = cnt + 1
                    stats(1) = min(stats(1),minv)
                    stats(2) = max(stats(2),maxv)
                    stats(3) = stats(3) + meanv
                    stats(4) = stats(4) + stdevv**2.
                endif
            enddo
            if( cnt > 1 )then
                ! updates header, size, stack & removes box file
                stats(3) = stats(3) / real(cnt)
                stats(4) = sqrt(stats(4) / real(cnt))
                select case(which)
                    case('even')
                        call cavgs_even(1)%update_header_stats(fname,stats)
                    case('odd')
                        call cavgs_odd(1)%update_header_stats(fname,stats)
                    case('merged')
                        call cavgs_merged(1)%update_header_stats(fname,stats)
                end select
            endif
        end subroutine update_stats

    end subroutine cavger_write

    !>  \brief  reads class averages from disk
    subroutine cavger_read( fname, which )
        character(len=*),  intent(in) :: fname, which
        integer :: icls
        if( .not. file_exists(fname) )then
            THROW_HARD(trim(fname)//' not in cwd')
        endif
        select case(which)
            case('even')
                do icls=1,ncls
                    call cavgs_even(icls)%new(ldim,smpd,wthreads=.false.)
                    call cavgs_even(icls)%read(fname, icls)
                end do
            case('odd')
                do icls=1,ncls
                    call cavgs_odd(icls)%new(ldim,smpd,wthreads=.false.)
                    call cavgs_odd(icls)%read(fname, icls)
                end do
            case('merged')
                 do icls=1,ncls
                    call cavgs_merged(icls)%new(ldim,smpd,wthreads=.false.)
                    call cavgs_merged(icls)%read(fname, icls)
                end do
            case DEFAULT
                THROW_HARD('unsupported which flag')
        end select
    end subroutine cavger_read

    !>  \brief  writes partial class averages to disk (distributed execution)
    subroutine cavger_readwrite_partial_sums( which )
        character(len=*), intent(in)  :: which
        integer                       ::  icls
        character(len=:), allocatable :: cae, cao, cte, cto
        allocate(cae, source='cavgs_even_part'//int2str_pad(params_glob%part,params_glob%numlen)//params_glob%ext)
        allocate(cao, source='cavgs_odd_part'//int2str_pad(params_glob%part,params_glob%numlen)//params_glob%ext)
        allocate(cte, source='ctfsqsums_even_part'//int2str_pad(params_glob%part,params_glob%numlen)//params_glob%ext)
        allocate(cto, source='ctfsqsums_odd_part'//int2str_pad(params_glob%part,params_glob%numlen)//params_glob%ext)
        select case(trim(which))
            case('read')
                if( .not. file_exists(cae) )then
                    THROW_HARD(trim(cae)//' does not exist')
                endif
                if( .not. file_exists(cao) )then
                    THROW_HARD(trim(cao)//' does not exist')
                endif
                do icls=1,ncls
                    call cavgs_even( icls)%read(cae, icls)
                    call cavgs_odd( icls)%read(cao, icls)
                    call ctfsqsums_even( icls)%read(cte, icls)
                    call ctfsqsums_odd( icls)%read(cto, icls)
                end do
            case('write')
                do icls=1,ncls
                    call cavgs_even( icls)%write(cae, icls)
                    call cavgs_odd( icls)%write(cao, icls)
                    call ctfsqsums_even( icls)%write(cte, icls)
                    call ctfsqsums_odd( icls)%write(cto, icls)
                end do
            case DEFAULT
                THROW_HARD('unknown which flag; only read & write supported; cavger_readwrite_partial_sums')
        end select
        deallocate(cae, cao, cte, cto)
    end subroutine cavger_readwrite_partial_sums

    subroutine cavger_apply_weights( w )
        real, intent(in) :: w
        integer :: icls
        !$omp parallel do default(shared) private(icls) schedule(static) proc_bind(close)
        do icls=1,ncls
            call cavgs_even(icls)%mul(w)
            call ctfsqsums_even(icls)%mul(w)
            call cavgs_odd(icls)%mul(w)
            call ctfsqsums_odd(icls)%mul(w)
        end do
        !$omp end parallel do
    end subroutine cavger_apply_weights

    !>  \brief  re-generates the object after distributed execution
    subroutine cavger_assemble_sums_from_parts
        type(image), allocatable :: imgs4read(:)
        character(len=:), allocatable :: cae, cao, cte, cto
        integer :: ipart,  icls
        call init_cavgs_sums
        allocate(imgs4read(4))
        call imgs4read(1)%new(ldim_pd, smpd)
        call imgs4read(1)%set_ft(.true.)
        call imgs4read(2)%new(ldim_pd, smpd)
        call imgs4read(2)%set_ft(.true.)
        call imgs4read(3)%new(ldim_pd, smpd)
        call imgs4read(3)%set_ft(.true.)
        call imgs4read(4)%new(ldim_pd, smpd)
        call imgs4read(4)%set_ft(.true.)
        do ipart=1,params_glob%nparts
            allocate(cae, source='cavgs_even_part'//int2str_pad(ipart,params_glob%numlen)//params_glob%ext)
            allocate(cao, source='cavgs_odd_part'//int2str_pad(ipart,params_glob%numlen)//params_glob%ext)
            allocate(cte, source='ctfsqsums_even_part'//int2str_pad(ipart,params_glob%numlen)//params_glob%ext)
            allocate(cto, source='ctfsqsums_odd_part'//int2str_pad(ipart,params_glob%numlen)//params_glob%ext)
            if( .not. file_exists(cae) )then
                THROW_HARD('file: '//trim(cae)//' does not exist; cavger_assemble_sums_from_parts')
            endif
            if( .not. file_exists(cao) )then
                THROW_HARD('file: '//trim(cao)//' does not exist; cavger_assemble_sums_from_parts')
            endif
            if( .not. file_exists(cte) )then
                THROW_HARD('file: '//trim(cte)//' does not exist; cavger_assemble_sums_from_parts')
            endif
            if( .not. file_exists(cto) )then
                THROW_HARD('file: '//trim(cto)//' does not exist; cavger_assemble_sums_from_parts')
            endif
            do icls=1,ncls
                call imgs4read(1)%read(cae, icls)
                call imgs4read(2)%read(cao, icls)
                call imgs4read(3)%read(cte, icls)
                call imgs4read(4)%read(cto, icls)
                call cavgs_even(icls)%add_workshare(imgs4read(1), cavgs_odd(icls),imgs4read(2),&
                    &ctfsqsums_even(icls), imgs4read(3), ctfsqsums_odd(icls), imgs4read(4))
            end do
            deallocate(cae, cao, cte, cto)
        end do
        call imgs4read(1)%kill
        call imgs4read(2)%kill
        call imgs4read(3)%kill
        call imgs4read(4)%kill
        deallocate(imgs4read)
        call cavger_merge_eos_and_norm()
    end subroutine cavger_assemble_sums_from_parts

    !>  \brief  corrects for Fourier domain bilinear interpolation
    subroutine cavger_prep_gridding_correction( img )
        class(image), intent(inout) :: img
        real    :: center(3),dist(2),pid,sinc,pad_sc
        integer :: i,j
        call img%new(ldim,smpd)
        if( l_bilinear )then
            center = real(ldim/2 + 1)
            pad_sc = 1. / real(ldim_pd(1))
            do i = 1,ldim(1)
                dist(1) = pad_sc*(real(i)-center(1))
                do j = 1,ldim(2)
                    dist(2) = pad_sc*(real(j)-center(2))
                    pid     = PI*sqrt(sum(dist**2.))
                    if( pid < TINY )then
                        sinc = 1.
                    else
                        sinc = sin(pid) / pid
                    endif
                    call img%set([i,j,1], sinc*sinc)
                enddo
            enddo
        else
            img = 1.
        endif
    end subroutine cavger_prep_gridding_correction

    ! destructor

    !>  \brief  is a destructor
    subroutine cavger_kill
        integer ::  icls, iprec
        if( exists )then
            do icls=1,ncls
                call cavgs_even(icls)%kill
                call cavgs_odd(icls)%kill
                call cavgs_merged(icls)%kill
                call ctfsqsums_even(icls)%kill
                call ctfsqsums_odd(icls)%kill
                call ctfsqsums_merged(icls)%kill
            end do
            deallocate( cavgs_even, cavgs_odd, cavgs_merged,&
            &ctfsqsums_even, ctfsqsums_odd, ctfsqsums_merged, pptcl_mask, prev_eo_pops)
            do iprec=1,partsz
                if( allocated(precs(iprec)%classes) ) deallocate(precs(iprec)%classes)
                if( allocated(precs(iprec)%states)  ) deallocate(precs(iprec)%states)
                if( allocated(precs(iprec)%ows)     ) deallocate(precs(iprec)%ows)
                if( allocated(precs(iprec)%e3s)     ) deallocate(precs(iprec)%e3s)
                if( allocated(precs(iprec)%shifts)  ) deallocate(precs(iprec)%shifts)
            end do
            deallocate(precs)
            istart        = 0
            iend          = 0
            partsz        = 0
            ncls          = 0
            l_is_class    = .true.
            l_hard_assign = .true.
            exists        = .false.
        endif
    end subroutine cavger_kill

end module simple_classaverager
