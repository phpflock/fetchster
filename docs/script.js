// Subtle scroll-reveal for cards, steps, and screenshots.
const observer = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        observer.unobserve(entry.target);
      }
    }
  },
  { threshold: 0.12 }
);

document.querySelectorAll(".reveal").forEach((el) => observer.observe(el));

// Live clock in the hero menu-bar mock.
const clock = document.getElementById("mb-clock");
if (clock) {
  const tick = () => {
    clock.textContent = new Date().toLocaleString("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
  };
  tick();
  setInterval(tick, 30000);
}
