# homemesh: the owner's brief

The owner's request, 2026-10-20 (lightly edited for reading):

> I want to create another scshafe-dev project for creating a 3D model of a
> home, detailing the ethernet access points (and their types), and then
> simulating various mesh arrangements in order to compare possible setups.
> I'd like it to be able to leverage architectural blueprints and photos or
> maybe a video walkthrough in order to create the model, and point out where
> you are okay with placing a router/extender/mesh node, and then once those
> variables are all set, be able to determine good strategies for planning
> out a mesh of routers.

The owner's choices on 2026-10-20:

- **Name:** homemesh.
- **Licence:** public, MIT. The tool is generic. A house's blueprints,
  photos, video, scans and model are private data. They live in a data
  directory outside git and never enter the repository, its issues, its CI
  logs or its fixtures. Test fixtures are synthetic houses.
- **Form:** a web app on the tailnet. The browser shows the house in 3D,
  edits it and shows the simulation results. A Python backend does the
  reconstruction, simulation and planning. It is deployed on the Arch PC
  through the runner lane, which has a GPU (an RX 6900 XT on ROCm). It is
  usable from the Mac, the phone and the PC.
- **Capture:** an iPhone LiDAR scan through Apple RoomPlan comes first, with
  blueprints alongside. RoomPlan measures the walls, doors, windows and
  openings. Blueprints add other floors, wall materials and anything the
  scan missed. Photos and a video walkthrough are reference material now
  and a reconstruction source later.

## Fixed points

- **A model of the home.**
  - It has floors, rooms, walls with materials and thicknesses, doors,
    windows, stairs and floor slabs, all at real scale.
  - Several floors are stacked in one coordinate frame.
  - Every element records where it came from: scan, blueprint, photo or
    manual edit.
- **The network's fixed facts.**
  - **Ethernet access points:** wall jacks and runs, with their type
    (Cat5e, Cat6, Cat6a or coax/MoCA) and whether each is live and where it
    leads.
  - **The internet entry point:** the modem or ONT.
  - **Power outlets,** where they matter.
- **The owner's placement rules.**
  - The owner marks where a router, extender or mesh node may go: allowed
    spots or zones, and places that are not allowed.
  - The owner marks where coverage matters, and how much: the office versus
    the garage, for example, and what each place needs (throughput,
    latency).
- **Equipment.** Devices are described as data: bands (2.4, 5 and 6 GHz),
  antennas or gain, transmit power, wired backhaul or wireless backhaul,
  the mesh system and its limits, and price. A catalogue of real models
  can grow over time.
- **Simulation.**
  - It predicts the signal (RSSI or SNR), and from that the estimated
    throughput, across the house per band, for any arrangement.
  - It counts walls and floors, using their materials.
  - It works out the backhaul between nodes, wired where a jack allows,
    wireless otherwise, and the throughput that results end to end.
  - The model is stated, with its assumptions. It is calibrated against
    real measurements when the owner takes some, such as a walk with a
    phone's Wi-Fi readings.
- **Planning.**
  - It searches the arrangements the placement rules allow, and ranks
    them by coverage of the places that matter, throughput, cost and node
    count.
  - It explains why an arrangement wins.
  - It compares arrangements side by side: heat maps per floor, and a
    table.
- **Capture for real houses.**
  - A small iOS capture app (Swift, RoomPlan) scans a room or several and
    uploads the CapturedRoom export, USDZ plus JSON, to the backend.
  - Blueprint import scales an image or PDF from one known dimension. The
    owner then traces or corrects the walls and marks their materials.

## The designer's job (first PR)

1. Write `docs/design.md`:
   - the data model;
   - the propagation model: for example a multi-wall/floor model (COST 231
     multi-wall, ITU-R P.1238) to start, ray tracing later if it earns its
     place, with each choice argued;
   - the backhaul model;
   - the planner (search over candidate spots: exhaustive, greedy or
     ILP);
   - the stack: web 3D (three.js or similar), the Python backend, storage
     outside git, the RoomPlan import path, and the iOS app's scope;
   - the deployment on the runner lane: tailnet only, a door if it holds
     private data;
   - milestones.

   List every decision the owner must make in an "Owner decisions" section.
   Don't decide those yourself.
2. Set up the skeleton so `scripts/verify` and `dev check .` pass, with
   synthetic fixture houses only.
3. Build nothing past the skeleton until the owner accepts the design.
